# screen is 480 x 320 (32 bits)

use strict;
use v5.28;

use lib "/home/pi/display";
use Gather;
use Graphics;
use UserDetails qw ( $path_to_pictures $health_check_url $radio_stations_ref $jellyfin_url $jellyfin_apikey $display_times_ref );
use Input;
use Utils;
use Http;
use Audio;
use Photos;
use MQTT;

use IPC::MPS;
use IPC::MPS::Event;
use Event;
use AnyEvent::HTTP;
use JSON::Parse;

my $jellyfin_user_id;
my $pictures;           # ref to array of paths
my $mqtt_data_ref;      # ref to hash of MQTT data

use constant PLAYING_NOTHING => 0;
use constant PLAYING_RADIO => 1;
use constant PLAYING_PLAYLIST => 2;
use constant PLAYING_ALBUM => 3;
my $mode_playing_area = PLAYING_NOTHING;
# array of ref to hashes of params for playing mode display, inc "update_fn" => ref to function to update play mode area
my @playing_params = (
  {"update_fn" => \&update_nothing_playing}, 
  {"update_fn" => \&update_radio_playing, "stop" => \&transport_stop}, 
  {"update_fn" => \&update_playlist_playing, "stop" => \&transport_stop, "pause" => \&transport_pause, "play" => \&transport_play, "next" => \&playlist_next_track}, 
  {"update_fn" => \&update_album_playing, "stop" => \&transport_stop, "pause" => \&transport_pause, "play" => \&transport_play, "next" => \&album_next_track, "back" => \&album_prev_track});

use constant DISPLAY_SLIDESHOW => 0;
use constant DISPLAY_RADIO => 1;
use constant DISPLAY_PLAYLISTS => 2;
use constant DISPLAY_ALBUMS_LETTER => 3;
use constant DISPLAY_ALBUMS_ICON => 4;
use constant DISPLAY_ARTISTS_LETTER => 5;
use constant DISPLAY_ARTISTS_ICON => 6;
use constant DISPLAY_ARTISTS_ALBUM => 7;
use constant DISPLAY_HA => 8;
my $mode_display_area = DISPLAY_SLIDESHOW;
my @display_mode_headings = ("Slideshow", "Radio stations", "Playlists", "Albums by letter", "List of albums", "Artists by letter", "List of artists", "List of albums", "Home Assistant");
my @displaying_params = ({}, {}, {}, {}, {}, {}, {}, {}, {});
# array of refs to hashes of callbacks
my %footer_callbacks = ("photos" => \&display_slideshow, "radio" => \&display_radio, "playlists" => \&display_playlists, "albums" => \&display_albums_by_letter, "artists" => \&display_artists_by_letter, "homeauto" => \&display_ha);
# array of refs to hash of touch screen input areas (area_name => {x1, y1, x2, y2, cb})
my $footer_icon_areas = {};           # touch points in footer
my $transport_icon_areas = {};        # touch points in transport controls
my @input_areas;                      # touch points in display area
my @swipe_callbacks = (
  {}, 
  {"-up-" => \&display_radio_up, "-down-" => \&display_radio_down}, 
  {"-up-" => \&display_playlists_up, "-down-" => \&display_playlists_down}, 
  {}, 
  {"-up-" => \&display_albums_by_icon_up, "-down-" => \&display_albums_by_icon_down, "-left-" => \&display_albums_by_icon_left, "-right-" => \&display_albums_by_icon_right}, 
  {}, 
  {"-up-" => \&display_artists_by_icon_up, "-down-" => \&display_artists_by_icon_down, "-left-" => \&display_artists_by_icon_left, "-right-" => \&display_artists_by_icon_right}, 
  {"-up-" => \&display_artist_albums_by_icon_up, "-down-" => \&display_artist_albums_by_icon_down, "-left-" => \&display_artist_albums_by_icon_left, "-right-" => \&display_artist_albums_by_icon_right},
  {});

my %pids;
my $pictures_event;
my $music_event;
my $backlight_event;

my %callbacks;
my $num_callbacks;
my $music_library_key;
my $playlists_library_key;
my %thumbnails;                  # hash containing url of thumbnails that are being downloaded

# <artist name first letter> -> ref to hash 1 of:
#   <artists name> -> ref to hash 2 of:
#     id -> id of artist
#     name -> name of artist
#     albums -> ref to hash 3 of:
#       <album id> -> ref to hash 4 of:
#         title -> album name
#         artist -> ref to artists name hash 2
#         tracks -> ref to hash 5 of:
#           <index> -> ref to hash 6 of:
#             duration -> track length in ms
#             title -> track title
#             id -> id of media file
my %artists_by_letter;
my %artists_by_id;
my %album_id_to_artist_id;

# <playlist Id> -> ref to hash of
#   name -> playlist title
#   tracks -> ref to array of ref to hash of
#     id -> id of track
#     album_title -> title of album track is from
#     track_title -> title of track
#     artist_name -> name of artist
#     duration -> track length in ms
my %playlists;

# <album name first letter> -> ref to array of ref to hash 4 above (sorted by album name)
my %albums_by_letter;
my %tmp_albums_by_letter;

$SIG{'QUIT'} = $SIG{'HUP'} = $SIG{'INT'} = $SIG{'KILL'} = $SIG{'TERM'} = sub { exec("pkill perl"); exit; };

sub set_display_mode {
  my $new = shift;
  return if $new == $mode_display_area;
  print_error("Setting new display mode");
  $mode_display_area = $new;
  $playing_params[$mode_playing_area]->{"update_fn"}();
  print_heading($display_mode_headings[$mode_display_area]);
  stop_displaying_pictures() if $mode_display_area != DISPLAY_SLIDESHOW;
  start_displaying_pictures() if $mode_display_area == DISPLAY_SLIDESHOW;
}

sub set_play_mode {
  $mode_playing_area = shift;
  clear_play_area(($mode_display_area == DISPLAY_SLIDESHOW) ? 0 : 1) if $mode_playing_area == PLAYING_NOTHING;
}

sub stop_all_audio {
  snd($pids{"audio"}, "stop");
  `pkill vlc`;
}

sub remove_leading_article {
  my $text = shift;
  return substr($text, 4) if ($text =~ m/^The /);
  return substr($text, 2) if ($text =~ m/^A /);
  return $text;
}

sub update_nothing_playing {
  display_playing_nothing(($mode_display_area == DISPLAY_SLIDESHOW) ? 0 : 1);
}

#----------------------------------------------------------------------------------------------------------------------
sub check_and_display {
  if (!defined $pictures) {
    print_error("Gathering list of pictures");
    display_string("Gathering list of pictures", 1);
  } else {
    my $num_pics = scalar @$pictures;
    if ($num_pics == 0) {
      print_error("No pictures found");
      display_string("No pictures found", 1);
    } else {
      my $path = $$pictures[int(rand($num_pics))];
      if (-e "images/sleeping.png") {
        my @time = localtime();
        if (($time[2] > 21) || ($time[2] < 9)) {
          $path = "images/sleeping.png";
        }
      }
      snd($pids{"Photos"}, "prepare", $path);
    }
  }
}

sub stop_displaying_pictures {
  $pictures_event->stop;
}

sub start_displaying_pictures {
  $pictures_event->start;
}

#----------------------------------------------------------------------------------------------------------------------
sub display_slideshow {
  print_error("Back to displaying pictures");
  clear_display_area(1);
  if (!defined $pictures) {
    print_error("Gathering list of pictures");
    display_string("Gathering list of pictures", 1);
  } else {
    display_string("Please wait ...", 1);
  }
  set_display_mode(DISPLAY_SLIDESHOW);
}

#----------------------------------------------------------------------------------------------------------------------
sub gen_id {
  my @set = ('0' ..'9', 'A' .. 'Z', 'a' .. 'z');
  return join '' => map $set[rand @set], 1 .. 20;
};

sub add_apikey {
  my ($base, $key) = @_;
  if (index($base, "?") == -1) {
    return "$base?ApiKey=$key";
  } else {
    return "$base&ApiKey=$key";
  }
}

# got hash keys $a and $b automatically
sub album_sort {
  return remove_leading_article($a->{"title"}) cmp remove_leading_article($b->{"title"});
}

sub numeric_sort {
  return $a <=> $b;
}

sub get_json {
  my ($url, $cb) = @_;
  my $id = gen_id();
  $callbacks{$id} = $cb;
  snd($pids{"Http"}, "get_json", add_apikey($jellyfin_url . $url, $jellyfin_apikey), $id);
};

sub get_thumb {
  my ($image, $cb) = @_;
  #print_error("Fetching thumbnail for $image");
  return if $thumbnails{$image};        # return if already fetched this id
  $thumbnails{$image} = 1;
  my $id = gen_id();
  $callbacks{$id} = $cb;
  snd($pids{"Http"}, "get_thumb", $image, $id);
};

sub call_callback {
  my ($from, $json, $status, $id, $url) = @_;
  my $cb = $callbacks{$id};
  delete $callbacks{$id};
  &$cb($json, $status, $url) if $cb;
  if (scalar(keys %callbacks) == 0) {
    compile_list_of_albums();
    print_error("Done gathering music");
    %albums_by_letter = (%tmp_albums_by_letter);
    %tmp_albums_by_letter = undef;
  }
}

# Check that arg1 is a ref to a hash containing a key for arg2
# return 0 if check fails, else 1
sub check_hash_for_item {
  my $ref = shift;
  my $key = shift;
  if (ref($ref) ne "HASH") {
    print_error("Expecting HASH in JSON with $key");
    return 0;
  }
  my %hash = %$ref;
  if (! $hash{$key}) {
    print_error("No $key in JSON");
    return 0;
  }
  return 1;
}

# Check that arg1 is a ref to an array
# return 0 if check fails, else 1
sub check_array {
  my $ref = shift;
  if (ref($ref) ne "ARRAY") {
    print_error("Expecting ARRAY in JSON");
    return 0;
  }
  return 1;
}

sub find_artist_ref {
  my $name = shift;
  my $ref = $artists_by_letter{uc substr($name, 0, 1)}->{$name};
  if (defined $ref) {
    return $ref;
  }
  print_error("Ooops, can't find artist data for $name");
  return undef;
}

sub get_albums_tracks {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  return unless check_hash_for_item($json, "Items");
  my $ref = $$json{"Items"};
  return unless check_array($ref);
  my $album_id = $$ref[0]->{"AlbumId"};
  #print_error("parsing tracks for album $album_id which has tracks no. = " . scalar @$ref);
  my $artist_id = $album_id_to_artist_id{$album_id};
  my $artist_name = $artists_by_id{$artist_id};
  utf8::decode($artist_name);
  my $artist_data_ref = find_artist_ref($artist_name);
  return unless (defined $artist_data_ref);
  my $albums_ref = $$artist_data_ref{"albums"};
  my $album_data_ref = $$albums_ref{$album_id};
  return unless (defined $album_data_ref);
  my %tracks;                                       # hash of tracks on the album
  foreach my $track_ref (@$ref) {
    return if $$track_ref{"Type"} ne "Audio";
    my $t = 0;
    if ($$track_ref{"IndexNumber"}) {
      $t = $$track_ref{"IndexNumber"};
    }
    $tracks{$t} = {};
    $tracks{$t}->{"duration"} = $$track_ref{"RunTimeTicks"} / 10000;
    $tracks{$t}->{"title"} = $$track_ref{"Name"};
    utf8::decode($tracks{$t}->{"title"});
    $tracks{$t}->{"id"} = $$track_ref{"Id"};
    #print_error($tracks{$t}->{"id"});
  }
  $$album_data_ref{"tracks"} = \%tracks;
  return 1;
}

sub get_parentId_from_url {
  my $str = shift;
  my $pos = index($str, "parentId=");
  return if $pos == -1;
  return substr($str, $pos + 9, 32);
}

# get data for an artist and their albums
sub get_artists_albums {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  return unless check_hash_for_item($json, "Items");
  my $albums_ref = $$json{"Items"};
  return unless check_array($albums_ref);
  my $artist_id = get_parentId_from_url($url);
  my $artist_name = $artists_by_id{$artist_id};
  utf8::decode($artist_name);
  my $artist_data_ref = find_artist_ref($artist_name);
  return unless (defined $artist_data_ref);
  my $hash_ref;                                 # ref to hash of album data
  if ($$artist_data_ref{"albums"}) {
    $hash_ref = $$artist_data_ref{"albums"};
  } else {
    $hash_ref = {};
  }
  my $ref;
  foreach $ref (@$albums_ref) {
    next unless check_hash_for_item($ref, "Name");
    next if $$ref{"Type"} ne "MusicAlbum";
    $album_id_to_artist_id{$$ref{"Id"}} = $artist_id;
    $$hash_ref{$$ref{"Id"}} = {} unless $$hash_ref{$$ref{"Id"}};
    $$hash_ref{$$ref{"Id"}}->{"id"} = $$ref{"Id"};
    get_thumb($$ref{"Id"}) if $$ref{"Id"};
    $$hash_ref{$$ref{"Id"}}->{"title"} = $$ref{"Name"};
    utf8::decode($$hash_ref{$$ref{"Id"}}->{"title"});
    $$hash_ref{$$ref{"Id"}}->{"artist"} = $artist_data_ref;
    #print_error("Album = " . $$ref{"Name"} . ", id = " . $$ref{"Id"} . ", user id = $jellyfin_user_id");
    get_json("/Items?userId=$jellyfin_user_id&parentId=" . $$ref{"Id"}, sub {parse_error() if !get_albums_tracks(@_);});
  }
  foreach my $key (keys %$hash_ref) {                  # now check for any deleted albums
    my $found = 0;
    foreach $ref (@$albums_ref) {
      if ($key eq $$ref{"key"}) {
        $found = 1;
        last;
      }
    }
    delete $$hash_ref{$ref} unless $found;
  }
  $$artist_data_ref{"albums"} = $hash_ref unless $$artist_data_ref{"albums"};
  return 1;
}

# parse music library top level, which lists all album artists
sub process_music_library {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  return unless check_hash_for_item($json, "Items");
  my $ref = $$json{"Items"};
  return unless check_array($ref);
  foreach $ref (@$ref) {
    next unless check_hash_for_item($ref, "Name");             # check artist has a name
    next if $$ref{"Type"} ne "MusicArtist";
    utf8::decode($$ref{"Name"});
    $artists_by_id{$$ref{"Id"}} = $$ref{"Name"};
    #print_error("Found artist " . $$ref{"Name"});
    my $first_char = uc substr($$ref{"Name"}, 0, 1);              # get first char of name
    if (! defined $artists_by_letter{$first_char}) {
      $artists_by_letter{$first_char} = {};
    }
    my $data_ref = $artists_by_letter{$first_char};
    my $artist_ref;
    if ($$data_ref{$$ref{"Name"}}) {
      $artist_ref = $$data_ref{$$ref{"Name"}};
    } else {
      $artist_ref = {};
    }
    $$artist_ref{"id"} = $$ref{"Id"};
    get_thumb($$artist_ref{"id"}) if $$artist_ref{"id"};
    $$artist_ref{"name"} = $$ref{"Name"};
    #print_error("added artist " . $$artist_ref{"name"} . " with id " . $$ref{"Id"});
    $$data_ref{$$ref{"Name"}} = $artist_ref unless $$data_ref{$$ref{"Name"}};
    get_json("/Items?userId=$jellyfin_user_id&parentId=" . $$ref{"Id"}, sub {parse_error() if !get_artists_albums(@_);});
  }
  return 1;
}

# parse list of top level folders, which will be photos and music
sub process_library_sections {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  return unless check_hash_for_item($ref, "Items");
  my %hash = %$ref;
  $ref = $hash{"Items"};
  return unless check_array($ref);
  my @array = @$ref;
  foreach my $i (@array) {
    if (check_hash_for_item($i, "CollectionType")) {
      if (($$i{"CollectionType"} eq "music") and ($$i{"Path"} =~ /Music/)) {                     # music library
        $music_library_key = $$i{"Id"};
      }
    }
  }
  return unless $music_library_key;
  get_json("/Items?userId=$jellyfin_user_id&parentId=$music_library_key", sub {parse_error() if !process_music_library(@_);});
  #print_error("Start looking for playlists");
  foreach my $i (@array) {
    if (check_hash_for_item($i, "CollectionType")) {
      if ($$i{"CollectionType"} eq "playlists") {                     # playlists library
        $playlists_library_key = $$i{"Id"};
      }
    }
  }
  return unless $playlists_library_key;
  get_json("/Items?userId=$jellyfin_user_id&parentId=$playlists_library_key", sub {parse_error() if !process_playlists_top(@_);});
  return 1;
}

sub parse_error {
  print_error("Hmm, something went wrong here");
}

# parse playlists
sub process_playlist_items {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  return unless check_hash_for_item($ref, "Items");
  my %hash = %$ref;
  $ref = $hash{"Items"};
  my $playlist_id = get_parentId_from_url($url);
  my @tracks = ();
  return unless check_array($ref);
  my @array = @$ref;
  foreach my $track_ref (@array) {
    next unless check_hash_for_item($track_ref, "RunTimeTicks");
    my %track_info;
    $track_info{"duration"} = $$track_ref{"RunTimeTicks"} / 10000;
    $track_info{"album_id"} = $$track_ref{"AlbumId"};
    $track_info{"album_title"} = $$track_ref{"Album"};
    utf8::decode($track_info{"album_title"});
    $track_info{"track_title"} = $$track_ref{"Name"};
    utf8::decode($track_info{"track_title"});
    $track_info{"artist_name"} = $$track_ref{"AlbumArtist"};
    utf8::decode($track_info{"artist_name"});
    $track_info{"id"} = $$track_ref{"Id"};
    get_thumb($$track_ref{"Id"}) if $$track_ref{"Id"};
    #print_error("Playlast track id = $track_info{'id'}");
    push(@tracks, \%track_info);
    #print_error("Added track $track_info{'track_title'} // $track_info{'artist_name'} to playlist $playlist_id");
  }
  $playlists{$playlist_id}->{"tracks"} = \@tracks;
  return 1;
}

# parse list of playlists
sub process_playlists_top {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  #print_error("Looking for list of playlists");
  return unless check_hash_for_item($ref, "Items");
  my %hash = %$ref;
  $ref = $hash{"Items"};
  return unless check_array($ref);
  my @array = @$ref;
  foreach my $i (@array) {
    if (check_hash_for_item($i, "Type")) {
      if ($$i{"Type"} eq "Playlist") {                     # audio playlist
        if (check_hash_for_item($i, "Name") && check_hash_for_item($i, "Id")) {
          utf8::decode($$i{"Name"});
          #print_error("Found playlist " . $$i{"Name"});
          $playlists{$$i{"Id"}} = {};
          $playlists{$$i{"Id"}}->{"name"} = $$i{"Name"};
          get_thumb($$i{"Id"});
          get_json("/Items?userId=$jellyfin_user_id&parentId=" . $$i{"Id"}, sub {parse_error() if !process_playlist_items(@_);});
        }
      }
    }
  }
  return 1;
}

sub extract_jellyfin_user_id {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  return unless check_array($ref);
  $jellyfin_user_id = $$ref[0]->{"Id"};
  print_error("Found JellyFin user Id ($jellyfin_user_id)");
  return 1;
}

sub find_jellyfin_user_id {
  my $cb = shift;
  get_json("/Users", sub{
    if (!extract_jellyfin_user_id(@_)) {
      parse_error();
      sleep(60);
    }
    &$cb();
  });
}

sub gather_music {
  if (audio_state() != 0) {
    print_error("Postpone gathering music as currently playing");
    return;
  }
  if (! defined $jellyfin_user_id) {
    print_error("Jellyfin user Id not defined");
    find_jellyfin_user_id(sub {gather_music();});
    return;
  }
  print_error("Start gathering music");
  %thumbnails = ();
  #get_json("/playlists", sub {parse_error() if !process_playlists_top(@_);});
  get_json("/Library/MediaFolders", sub {parse_error() if !process_library_sections(@_);});
}

sub compile_list_of_albums {
  %tmp_albums_by_letter = ();
  print_error("Starting album compilation");
  foreach my $artist_letter (keys %artists_by_letter) {
    my %hash1 = %{$artists_by_letter{$artist_letter}};
    foreach my $artist_name (keys %hash1) {
      my %hash2 = %{$hash1{$artist_name}};
      my %hash3 = %{$hash2{"albums"}};
      foreach my $album_key (keys %hash3) {
        my $album_first_letter = uc substr(remove_leading_article($hash3{$album_key}->{"title"}), 0, 1);
        my $alphanumerics = join('', ('0' ..'9', 'A' .. 'Z'));
        if (index($alphanumerics, $album_first_letter) == -1) {
          $album_first_letter = "#";
        }
        if (! $tmp_albums_by_letter{$album_first_letter}) {
          my @empty = ($hash3{$album_key});
          $tmp_albums_by_letter{$album_first_letter} = \@empty;
        } else {
          push(@{$tmp_albums_by_letter{$album_first_letter}}, $hash3{$album_key});
        }
      }
    }
  }
  foreach my $letter (keys %tmp_albums_by_letter) {
    @{$tmp_albums_by_letter{$letter}} = sort album_sort @{$tmp_albums_by_letter{$letter}};
  }
}

#----------------------------------------------------------------------------------------------------------------------
# Update the input/index for the first icon to display
# Return true if the input/index has changed
sub calc_new_index {
  my ($ref, $max, $arg) = @_;
  my $dparms = $displaying_params[$mode_display_area];
  my $index = $dparms->{"index"};
  my $input = $dparms->{"input"};
#  my $max = scalar @{$ref->{$input}};
  if ($arg eq "-up-") {
    $dparms->{"index"} -= 6 if $dparms->{"index"} > 0;
    return ($index != $dparms->{"index"});
  } else {
    if ($arg eq "-down-") {
      $dparms->{"index"} += 6 if $max - 6 >= $dparms->{"index"};
      return ($index != $dparms->{"index"});
    } else {
      if ($arg eq "-left-") {
        my @letters = sort keys %$ref;
        foreach my $j (0 .. $#letters - 1) {
          if ($letters[$j] eq $input) {
            $dparms->{"input"} = $letters[$j + 1];
            $dparms->{"index"} = 0;
            last;
          }
        }
        return ($input ne $dparms->{"input"}); 
      } else {
        if ($arg eq "-right-") {
          my @letters = sort keys %$ref;
          foreach my $j (1 .. $#letters) {
            if ($letters[$j] eq $input) {
              $dparms->{"input"} = $letters[$j - 1];
              $dparms->{"index"} = 0;
              last;
            }
          }
          return ($input ne $dparms->{"input"});
        } else {
          return 1;
        }
      }
    }
  }
}

#----------------------------------------------------------------------------------------------------------------------
sub display_ha {
  clear_display_area(0);
  set_display_mode(DISPLAY_HA);
  display_home_assistant($mqtt_data_ref, 1);
  my %inputs = ();
  $input_areas[DISPLAY_HA] = \%inputs;
}

#----------------------------------------------------------------------------------------------------------------------
# display grid of first characters of artist names
sub display_artists_by_letter {
  clear_display_area(0);
  set_display_mode(DISPLAY_ARTISTS_LETTER);
  my %inputs = ();
  if (scalar keys %artists_by_letter) {                # artist list is available?
    foreach my $letter (keys %artists_by_letter) {
      $inputs{$letter} = {"cb" => \&display_artists_by_icon};
    }
    display_artists_top(\%inputs);
  } else {                                            # still waiting for artist list to be compiled
    display_string("Please wait ...", 0);
  }
  $displaying_params[DISPLAY_ARTISTS_ICON]->{"index"} = 0;
  $input_areas[DISPLAY_ARTISTS_LETTER] = \%inputs;
}

sub display_artists_by_icon_core {
  my ($input, $arg) = @_;
  $input = $displaying_params[DISPLAY_ARTISTS_ICON]->{"input"} unless $input;
  $displaying_params[DISPLAY_ARTISTS_ICON]->{"input"} = $input;                 # remember letter we are displaying
  $displaying_params[DISPLAY_ARTISTS_ICON]->{"index"} = 0 if ! defined $arg;
  set_display_mode(DISPLAY_ARTISTS_ICON);
  if (calc_new_index(\%artists_by_letter, scalar keys %{$artists_by_letter{$input}}, $arg)) {
    clear_display_area(0);
    my %inputs = ();
    $input = $displaying_params[DISPLAY_ARTISTS_ICON]->{"input"};
    display_artists_with_letter($artists_by_letter{$input}, $displaying_params[DISPLAY_ARTISTS_ICON]->{"index"}, \%inputs);
    foreach my $key (keys %inputs) {
      $inputs{$key}->{"cb"} = \&display_artist_albums_by_icon;
    }
    $input_areas[DISPLAY_ARTISTS_ICON] = \%inputs;
  }
}

sub display_artists_by_icon {
  my $input = shift;
  display_artists_by_icon_core($input, undef);
}

sub display_artists_by_icon_up {
  display_artists_by_icon_core(undef, "-up-");
}

sub display_artists_by_icon_down {
  display_artists_by_icon_core(undef, "-down-");
}

sub display_artists_by_icon_left {
  display_artists_by_icon_core(undef, "-left-");
}

sub display_artists_by_icon_right {
  display_artists_by_icon_core(undef, "-right-");
}

sub display_artist_albums_by_icon_core {
  my ($input, $arg) = @_;
  $input = $displaying_params[DISPLAY_ARTISTS_ALBUM]->{"input"} unless $input;
  $displaying_params[DISPLAY_ARTISTS_ALBUM]->{"input"} = $input;                 # remember artist we are displaying
  $displaying_params[DISPLAY_ARTISTS_ALBUM]->{"index"} = 0 if ! defined $arg;
  set_display_mode(DISPLAY_ARTISTS_ALBUM);
  my $ref = $artists_by_letter{$displaying_params[DISPLAY_ARTISTS_ICON]->{"input"}};
  if (calc_new_index($ref, scalar(keys %{$ref->{$input}->{"albums"}}), $arg)) {
    clear_display_area(0);
    my %inputs = ();
    $input = $displaying_params[DISPLAY_ARTISTS_ALBUM]->{"input"};
    display_artist_albums_with_letter($ref->{$input}, $displaying_params[DISPLAY_ARTISTS_ALBUM]->{"index"}, \%inputs);
    foreach my $key (keys %inputs) {
      $inputs{$key}->{"cb"} = \&play_album;
    }
    $input_areas[DISPLAY_ARTISTS_ALBUM] = \%inputs;
  }
}

sub display_artist_albums_by_icon {
  my $input = shift;
  display_artist_albums_by_icon_core($input, undef);
}

sub display_artist_albums_by_icon_up {
  display_artist_albums_by_icon_core(undef, "-up-");
}

sub display_artist_albums_by_icon_down {
  display_artist_albums_by_icon_core(undef, "-down-");
}

sub display_artist_albums_by_icon_left {
  display_artist_albums_by_icon_core(undef, "-left-");
}

sub display_artist_albums_by_icon_right {
  display_artist_albums_by_icon_core(undef, "-right-");
}

#----------------------------------------------------------------------------------------------------------------------
# display grid of first characters of album names
sub display_albums_by_letter {
  clear_display_area(0);
  set_display_mode(DISPLAY_ALBUMS_LETTER);
  my %inputs = ();
  if (scalar keys %albums_by_letter) {                # album list is available?
    foreach my $letter (keys %albums_by_letter) {
      $inputs{$letter} = {"cb" => \&display_albums_by_icon};
    }
    display_albums_top(\%inputs);
  } else {                                            # still waiting for album list to be compiled
    display_string("Please wait ...", 0);
  }
  $displaying_params[DISPLAY_ALBUMS_ICON]->{"index"} = 0;
  $input_areas[DISPLAY_ALBUMS_LETTER] = \%inputs;
}

sub display_albums_by_icon_core {
  my ($input, $arg) = @_;
  $input = $displaying_params[DISPLAY_ALBUMS_ICON]->{"input"} unless $input;
  $displaying_params[DISPLAY_ALBUMS_ICON]->{"input"} = $input;                 # remember letter we are displaying
  $displaying_params[DISPLAY_ALBUMS_ICON]->{"index"} = 0 if ! defined $arg;
  set_display_mode(DISPLAY_ALBUMS_ICON);
  if (calc_new_index(\%albums_by_letter, scalar @{$albums_by_letter{$input}}, $arg)) {
    clear_display_area(0);
    my %inputs = ();
    $input = $displaying_params[DISPLAY_ALBUMS_ICON]->{"input"};
    display_albums_with_letter($albums_by_letter{$input}, $displaying_params[DISPLAY_ALBUMS_ICON]->{"index"}, \%inputs);
    foreach my $key (keys %inputs) {
      $inputs{$key}->{"cb"} = \&play_album;
    }
    $input_areas[DISPLAY_ALBUMS_ICON] = \%inputs;
  }
}

sub display_albums_by_icon {
  my ($input) = @_;
  display_albums_by_icon_core($input, undef);
}

sub display_albums_by_icon_up {
  display_albums_by_icon_core(undef, "-up-");
}

sub display_albums_by_icon_down {
  display_albums_by_icon_core(undef, "-down-");
}

sub display_albums_by_icon_left {
  display_albums_by_icon_core(undef, "-left-");
}

sub display_albums_by_icon_right {
  display_albums_by_icon_core(undef, "-right-");
}

sub play_album {
  my ($input) = @_;
  print_error("play $input");
  # need to look through albums_by_letter to find match with $input
  my $album_ref;
  foreach my $letter (keys %albums_by_letter) {
    my @albums = @{$albums_by_letter{$letter}};
    foreach my $ref (@albums) {
      my $tracks_ref = $$ref{"tracks"};
      if ($input eq $$ref{"artist"}->{"name"} . "/" . $$ref{"title"} . "/" . $tracks_ref->{(keys %$tracks_ref)[0]}->{"id"}) {
        $album_ref = $ref;
        last;
      }
    }
    last if $album_ref;
  }
  unless ($album_ref) {
    print_error("oops, can't find album uid $input");
    display_slideshow();
    return;
  }
  $playing_params[PLAYING_ALBUM]->{"album_ref"} = $album_ref;                         # remember the album we are playing
  my @tracks = sort numeric_sort keys %{$album_ref->{"tracks"}};
  #print_error("Tracks in album: @tracks");
  my @paths;
  foreach my $i (@tracks) {
    #print_error($album_ref->{"tracks"}->{$i}->{"id"} . ", " . $album_ref->{"tracks"}->{$i}->{"title"});
    my $p = "$jellyfin_url/Items/" . $album_ref->{"tracks"}->{$i}->{"id"} . "/Download?ApiKey=$jellyfin_apikey";
    #print_error("Adding track $i: $p");
    $paths[$i] = $p;
  }
  $playing_params[PLAYING_ALBUM]->{"paths_array_ref"} = \@paths;                      # remember the tracks we are playing (note that not all array entries are used)
  unless (scalar @paths) {
    print_error("oops, can't find any valid tracks on album with uid $input");
    display_slideshow();
    return;
  }
  delete $playing_params[PLAYING_ALBUM]->{"track"};
  foreach my $i (0 .. scalar @paths - 1) {            # find first track
    #my $track_url = $album_ref->{"tracks"}->{$tracks[0]}->{"url"};
    #print_error("track url $track_url");
    my $p = $paths[$i];
    if ($p) {
      $playing_params[PLAYING_ALBUM]->{"track"} = $i;                                 # remember the track we are playing
      last;
    }
  }
  snd($pids{"audio"}, "init");
  snd($pids{"audio"}, "play", $playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$playing_params[PLAYING_ALBUM]->{"track"}]);
  $playing_params[PLAYING_ALBUM]->{"paused"} = 0;
  set_play_mode(PLAYING_ALBUM);
  update_album_playing();
}

sub update_album_playing {
  my $full = ($mode_display_area == DISPLAY_SLIDESHOW) ? 0 : 1;
  display_playing_album($playing_params[PLAYING_ALBUM]->{"album_ref"}, $playing_params[PLAYING_ALBUM]->{"track"}, $full, \$transport_icon_areas, $playing_params[PLAYING_ALBUM]->{"paused"});
}

sub album_prev_track {
  my $current = $playing_params[PLAYING_ALBUM]->{"track"};
  delete $playing_params[PLAYING_ALBUM]->{"track"};
  #print_error("current track = $current");
  foreach my $i (reverse(0 .. $current - 1)) {
    if ($playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$i]) {
      #print_error("setting track to $i");
      $playing_params[PLAYING_ALBUM]->{"track"} = $i;                                 # move to the previous track
      last;
    }
  }
  $playing_params[PLAYING_ALBUM]->{"track"} = $current unless ($playing_params[PLAYING_ALBUM]->{"track"});                       # if we found another track to play
  snd($pids{"audio"}, "play", $playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$playing_params[PLAYING_ALBUM]->{"track"}]);
  update_album_playing();
}

sub album_next_track {
  $playing_params[PLAYING_ALBUM]->{"paused"} = 0;
  my $current = $playing_params[PLAYING_ALBUM]->{"track"};
  delete $playing_params[PLAYING_ALBUM]->{"track"};
  #print_error("current track = $current");
  foreach my $i ($current + 1 .. scalar @{$playing_params[PLAYING_ALBUM]->{"paths_array_ref"}} - 1) {
    if ($playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$i]) {
      #print_error("setting track to $i");
      $playing_params[PLAYING_ALBUM]->{"track"} = $i;                                 # move to the next track
      last;
    }
  }
  if ($playing_params[PLAYING_ALBUM]->{"track"}) {                       # if we found another track to play
    snd($pids{"audio"}, "play", $playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$playing_params[PLAYING_ALBUM]->{"track"}]);
    update_album_playing();
  } else {
    stop_all_audio();
    set_play_mode(PLAYING_NOTHING);
  }
}

#----------------------------------------------------------------------------------------------------------------------
sub display_playlists_core {
  my $arg = shift;
  #print_error("playlists $arg");
  if (calc_new_index(scalar(keys %playlists), $arg)) {
    my %inputs;
    clear_display_area(0);
    foreach my $id (keys %playlists) {
      $inputs{$id} = {"cb" => \&play_playlist};
    }
    display_playlists_top(\%inputs, \%playlists, $displaying_params[DISPLAY_PLAYLISTS]->{"index"});
    $input_areas[DISPLAY_PLAYLISTS] = \%inputs;
    set_display_mode(DISPLAY_PLAYLISTS);
  }
}

sub display_playlists {
  display_playlists_core();
}

sub display_playlists_down {
  display_playlists_core("-down-");
}

sub display_playlists_up {
  display_playlists_core("-up-");
}

sub update_playlist_playing {
  my $full = ($mode_display_area == DISPLAY_SLIDESHOW) ? 0 : 1;
  display_playing_playlist($playing_params[PLAYING_PLAYLIST]->{"playlist"}, \%playlists, $playing_params[PLAYING_PLAYLIST]->{"track"}, $full, \$transport_icon_areas, $playing_params[PLAYING_PLAYLIST]->{"paused"});
}

sub play_playlist {
  my ($input) = @_;
  print_error("play playlist $input " . $playlists{$input}->{"name"});
  $playing_params[PLAYING_PLAYLIST]->{"playlist"} = $input;
  my $tracks_ref = $playlists{$input}->{"tracks"};
  if (defined $tracks_ref) {
    $playing_params[PLAYING_PLAYLIST]->{"track"} = int rand(scalar @$tracks_ref);
    snd($pids{"audio"}, "init");
    snd($pids{"audio"}, "play", "$jellyfin_url/Items/" . $playlists{$input}->{'tracks'}->[$playing_params[PLAYING_PLAYLIST]->{'track'}]->{'id'} . "/Download?ApiKey=$jellyfin_apikey");
    $playing_params[PLAYING_PLAYLIST]->{"paused"} = 0;
    set_play_mode(PLAYING_PLAYLIST);
    update_playlist_playing();
  } else {
    display_string("Please wait ...", 0);
  }
}

sub playlist_next_track {
  my $title = $playing_params[PLAYING_PLAYLIST]->{"playlist"};
  my $track_ref = $playlists{$title}->{"tracks"};
  my $track_no = $playing_params[PLAYING_PLAYLIST]->{"track"};
  if (scalar @$track_ref) {                                 # if only one track in array, leave it at same value (0)
    delete $playing_params[PLAYING_PLAYLIST]->{"track"};
    while (1) {
      $playing_params[PLAYING_PLAYLIST]->{"track"} = int rand(scalar @$track_ref);
      last if $playing_params[PLAYING_PLAYLIST]->{"track"} != $track_no;    # only break out of loop once we have a different track number
    }
  }
  snd($pids{"audio"}, "play", "$jellyfin_url/Items/" . $playlists{$title}->{'tracks'}->[$playing_params[PLAYING_PLAYLIST]->{'track'}]->{'id'} . "/Download?ApiKey=$jellyfin_apikey");
  update_playlist_playing();
}

#----------------------------------------------------------------------------------------------------------------------
sub display_radio_core {
  my $arg = shift;
  if (calc_new_index(scalar(keys %$radio_stations_ref), $arg)) {
    clear_display_area(0);
    my %inputs;
    foreach my $label (keys %$radio_stations_ref) {
      $inputs{$label} = {"cb" => \&play_radio};
    }
    display_radio_top(\%inputs, $radio_stations_ref, $displaying_params[DISPLAY_RADIO]->{"index"});
    $input_areas[DISPLAY_RADIO] = \%inputs;
    set_display_mode(DISPLAY_RADIO);
  }
}

sub display_radio {
  display_radio_core();
}

sub display_radio_down {
  display_radio_core("-down-");
}

sub display_radio_up {
  display_radio_core("-up-");
}

sub update_radio_playing {
  my $full = ($mode_display_area == DISPLAY_SLIDESHOW) ? 0 : 1;
  display_playing_radio($playing_params[PLAYING_RADIO]->{"station"}, $radio_stations_ref, $full, \$transport_icon_areas);
}

sub play_radio {
  my ($input) = @_;
  print_error("play radio $input");
  snd($pids{"audio"}, "play", $radio_stations_ref->{$input}->{"url"});
  set_play_mode(PLAYING_RADIO);
  $playing_params[PLAYING_RADIO]->{"station"} = $input;
  update_radio_playing();
}

#----------------------------------------------------------------------------------------------------------------------
sub transport_stop {
  stop_all_audio();
  set_play_mode(PLAYING_NOTHING);
}

sub transport_pause {
  snd($pids{"audio"}, "pause");
  #print_error("transport pause");
  $playing_params[$mode_playing_area]->{"paused"} = 1;
  $playing_params[$mode_playing_area]->{"update_fn"}->();
}

sub transport_play {
  snd($pids{"audio"}, "pause");
  #print_error("transport play");
  $playing_params[$mode_playing_area]->{"paused"} = 0;
  $playing_params[$mode_playing_area]->{"update_fn"}->();
}

#----------------------------------------------------------------------------------------------------------------------
init_fb();
$footer_icon_areas = print_footer(qw(photos radio playlists albums artists homeauto));
print_heading($display_mode_headings[DISPLAY_SLIDESHOW]);

$pids{"audio"} = spawn {
  my $message_poll = Event->timer(after => 1, interval => 1, parked => 1, cb => sub {
    player_poll();
    return if audio_state();                  # return if playing or paused
    audio_stop();
    snd(0, "play_stopped");
  });
  receive {
    msg "init" => sub {
      audio_init(\$message_poll);
    };
    msg "play" => sub {
      my ($from, $path) = @_;
      audio_play($path);
    };
    msg "stop" => sub {
      audio_stop();
    };
    msg "pause" => sub {
      audio_pause_play();
    };
  };
};

# Note: Jellyfin does not like being hammered by http requests hence the ones for thumbnails are queued and serialised
$pids{"Http"} = spawn {
  receive {
    msg get_json => sub {
      my ($from, $url, $id) = @_;
      #print STDERR "Getting json file from $url\n";
      http_request(
        GET => $url, 
        sub {
          my ($body, $hdr) = @_;
          my $jp = JSON::Parse->new ();
          $jp->warn_only (1);
          #print_error($body);
          snd($from, "response", $body ? $jp->parse($body) : "", $$hdr{Status} =~ /^2/, $id, $url);
        });
    };
    msg get_thumb => sub {
      my ($from, $image, $id) = @_;
      my $url = "/Items/$image/Images/Primary?ApiKey=$jellyfin_apikey&format=Jpg";
      if (length($image) == 0) {                              # don't bother if image id is blank
        snd($from, "response", undef, undef, $id, $url);
        return;
      }
      #print_error "Getting thumbnail file from $url";
      Http::download($url, undef, "thumbnail_cache", sub {
        my ($res, $http_resp_ref) = @_;                                   # $_[0] is 1 for ok, 0 for retriable error and undefined for error
        snd($from, "response", undef, $res, $id, $url);
      });
    };
  };
};

$pids{"GatherPictures"} = spawn {
  my $running;
  receive {
    Event->timer(after => 0, interval => 60 * 60 * 24, cb => sub {            # build list of pictures every 24 hours
      return if ($running);
      $running = 1;
      snd(0, "pictures", Gather::gather_pictures($path_to_pictures)); 
      print_error("Finishing gathering pictures");
      $running = 0;
    });
  };
};

$pids{"Input"} = spawn {
  receive {
    msg "start" => sub {
      my ($from, $ref) = @_;
      snd(0, "input", Input::input_task());
    };
  };
};

$pids{"Photos"} = spawn {
  receive {
    msg "prepare" => sub {
      my ($from, $fname) = @_;
      snd(0, "photo", Photos::prepare_photo_task($fname));
    };
  };
};

$pids{"MQTT"} = spawn {
  my $running = 0;
  sleep(60);               # give time for MQTT server to start, should replace this with check for mqtt process later
  Event->timer(interval => 30, cb => sub {            # check for new MQTT messages 30s
    return if ($running);
    $running = 1;
    #print_error("Checking for MQTT messages");
    my $data_ref = MQTT::get_mqtt_values();
    #print_hash_params($data_ref);
    snd(0, "mqtt", $data_ref); 
    $running = 0;
  });
  receive {
  };
};

$pids{"HealthCheck"} = spawn {                    # ping to healthcheck.io to say we're still running
  Event->timer(after => 10, interval => 55, cb => sub {  
    my @res = system("/bin/bash -c 'curl $health_check_url' > /dev/null 2>&1");
  });
  receive {
  };
};

$pictures_event = Event->timer(after => 0, interval => 10, cb => sub { check_and_display(); });         # slide show
snd($pids{"Input"}, "start", \$input_areas[$mode_display_area]);
snd($pids{"audio"}, "init");
turn_display_on();

$music_event = Event->timer(after => 0, interval => 60 * 2, cb => sub { 
  if (keys %thumbnails) {
    if ($music_event->interval == 60 * 2) {
      my $hour = (localtime())[2];
      if ($hour == 0) {
        $music_event->interval(3600 * 24);                    # rebuild list of music every midnight
      }
      return;
    }
  } 
  gather_music(); 
});

$backlight_event = Event->timer(after => 60, interval => 60 * 10, cb => sub {       # turn display on/off depending on yaml schedule
  my $hour = (localtime())[2];
  #print_error("backlight event at $hour");
  if ($hour == $$display_times_ref{"off-time"}) {
    turn_display_off();
    $backlight_event->interval(3600) if $backlight_event->interval < 3600;
  }
  if ($hour == $$display_times_ref{"on-time"}) {
    turn_display_on();
    $backlight_event->interval(3600) if $backlight_event->interval < 3600;
  }
});

receive {
  msg "pictures" => sub {
    my ($from, $ref) = @_;
    $pictures = $ref;
  };
  msg "photo" => sub {
    my ($from, $ref, $fname) = @_;
    #print_error("received photo message");
    if ($mode_display_area == DISPLAY_SLIDESHOW) {
      display_photo($ref, $fname);
    }
  };
  msg "input" => sub {
    my ($from, $final_x, $final_y, $init_x, $init_y) = @_;
    #print_error("Input = $final_x, $final_y, $init_x, $init_y");
    my $input = Input::what_input($input_areas[$mode_display_area], $footer_icon_areas, $transport_icon_areas, $final_x, $final_y, $init_x, $init_y);
    print_error("what_input: $input");
    snd($pids{"Input"}, "start");
    if (! defined $input) {
      print_error("Dumping input: $input");
    } else {
      if ($input_areas[$mode_display_area]->{$input}->{"cb"}) {             # first check for input in the display area
        $input_areas[$mode_display_area]->{$input}->{"cb"}->($input);
      } else {
        if (exists $footer_callbacks{$input}) {                             # now look for input in footer
          $footer_callbacks{$input}->();
        } else {
          if (exists $playing_params[$mode_playing_area]->{$input}) {                        # finally check transport icons
            $playing_params[$mode_playing_area]->{$input}->();
          } else {
            if (exists $swipe_callbacks[$mode_display_area]->{$input}) {                        # finally check transport icons
              $swipe_callbacks[$mode_display_area]->{$input}->();
            } else {
              print_error("No callback defined for $input");
            }
          }
        }
      }
    }
  };
  msg "response" => sub {
    call_callback(@_);
  };
  msg "play_stopped" => sub {
    album_next_track() if $mode_playing_area == PLAYING_ALBUM;
    playlist_next_track() if $mode_playing_area == PLAYING_PLAYLIST;
  };
  msg "mqtt" => sub {
    my ($from, $data_ref) = @_;
    #print_hash_params($data_ref);
    $mqtt_data_ref = $data_ref;
    if ($mode_display_area == DISPLAY_HA) {
      display_home_assistant($data_ref, 0);
    }
  };
};
