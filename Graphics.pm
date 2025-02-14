package Graphics;

use v5.28;
use strict;

our @EXPORT = qw ( init_fb clear_screen display_photo display_string display_albums_top display_albums_with_letter display_playing_album display_playlists_top display_playing_playlist 
  print_transport_icons display_artists_top display_artists_with_letter display_artist_albums_with_letter display_radio_top display_playing_radio print_heading print_footer display_playing_radio_details 
  clear_play_area clear_display_area prepare_photo display_home_assistant display_playing_nothing);
use base qw(Exporter);

use lib "/home/pi/display";

use Utils;
use MQTT;

use Graphics::Framebuffer;
use List::Util qw(min);
use File::Basename;
use Image::Resize;

my $fb;
use constant WIDTH => 720;
use constant HEIGHT => 1280;

my $screen_text_colour = {
   'red'   => 255,
   'green' => 255,
   'blue'  => 255,
   'alpha' => 255
};

my $letter_text_colour = {
   'red'   => 0,
   'green' => 0,
   'blue'  => 255,
   'alpha' => 255
};

my $letter_fill_colour = {
   'red'   => 255,
   'green' => 255,
   'blue'  => 0,
   'alpha' => 255
};

my $yellow = {
   'red'   => 255,
   'green' => 255,
   'blue'  => 0,
   'alpha' => 255
};

my $pale_yellow = {
   'red'   => 240,
   'green' => 240,
   'blue'  => 60,
   'alpha' => 255
};

my $black = {
   'red'   => 0,
   'green' => 0,
   'blue'  => 0,
   'alpha' => 255
};

my $white = {
   'red'   => 255,
   'green' => 255,
   'blue'  => 255,
   'alpha' => 255
};

my $green = {
   'red'   => 0,
   'green' => 255,
   'blue'  => 0,
   'alpha' => 255
};

my $dark_green = {
   'red'   => 50,
   'green' => 170,
   'blue'  => 20,
   'alpha' => 255
};

my $red = {
   'red'   => 255,
   'green' => 0,
   'blue'  => 0,
   'alpha' => 255
};

my $grey = {
   'red'   => 80,
   'green' => 80,
   'blue'  => 80,
   'alpha' => 255
};

my %orientations = (
  "1" => sub {},
  "2" => sub {my $image = shift; mirror(\$image, "horizontal");},
  "3" => sub {my $image = shift; rotate_cw(\$image, 180);},
  "4" => sub {my $image = shift; mirror(\$image, "vertical");},
  "5" => sub {my $image = shift; mirror(\$image, "horizontal"); rotate_cw($image, 270);},
  "6" => sub {my $image = shift; rotate_cw(\$image, 90);},
  "7" => sub {my $image = shift; mirror(\$image, "horizontal"); rotate_cw($image, 90);},
  "8" => sub {my $image = shift; rotate_cw(\$image, 270);},
  "" => sub {},
  "Unknown (0)" => sub {},
);

sub convert_colour_to_hex {
   my $colour = shift;
   return sprintf("%02x%02x%02x%02x", $$colour{"red"}, $$colour{"green"}, $$colour{"blue"}, $$colour{"alpha"});
}

sub clear_screen {
  $fb->set_color($black);
  $fb->rbox({
    'x'          => 0,
    'y'          => 120,
    'width'      => WIDTH,
    'height'     => HEIGHT - 242,
    'radius'     => 0,
    'pixel_size' => 1,
    'filled'     => 1
  });
}

sub display_string {
  my ($str, $full) = @_;
  clear_display_area($full);
  $fb->ttf_paragraph({
      'text'      => $str,
      'x'         => 10,
      'y'         => ($full) ? 600 : 400,
      'size'      => 50,
      'color'     => convert_colour_to_hex($screen_text_colour),
      'face'      => 'Commissioner-Regular.ttf',
      'justify'   => 'center',
      'line_spacing' => 0,
  });
}

# Returns the number of the last row in the image where a pixel is not black
# Args: ref to image hash
sub find_last_row {
  my $data = shift;
  my $image = $data->{"image"};
  my $width = $data->{"width"};
  my $height = $data->{"height"};
  #print_error("width = $width, height = $height");
  my $ch = 0;
  foreach my $r (reverse 0 .. $height - 1) {
    foreach my $c (reverse 0 .. $width - 1) {
      foreach my $rgb (0 .. 1) {
        $ch = ord substr($image, ($r * $width + $c) * 2 + $rgb, 1);
        #print_error("$r $c $rgb $ch") if $ch;
        return $r if $ch;
      }
    }
  }
}

sub print_footer {
  my @footer_names = @_;
  my %footer_areas;
  my $x = 0;
  foreach my $icon (@footer_names) {
    my $file = "images/" . $icon . "-icon.png";
    if (-e $file) {
      my $icon_image = $fb->load_image({
          'x'          => $x,
          'y'          => HEIGHT - 120,
          'file'       => $file
      });
      $fb->blit_write($icon_image);
    } else {
      print_error("Unable to load icon $file");
    }
    $footer_areas{$icon} = {'x1' => $x, 'y1' => HEIGHT - 120, 'x2' => $x + 119, 'y2' => HEIGHT};
    $x += 120;
  }
  $fb->set_color($yellow);
  $fb->line({
   'x'           => 0,
   'y'           => HEIGHT - 120,
   'xx'          => WIDTH - 1,
   'yy'          => HEIGHT - 120,
   'pixel_size'  => 4,
  });
  foreach my $i (1 .. 5) {
    $fb->line({
    'x'           => $i * 120,
    'y'           => HEIGHT - 120,
    'xx'          => $i * 120,
    'yy'          => HEIGHT - 1,
    'pixel_size'  => 4,
    });
  }
  return \%footer_areas;
}

sub init_fb {
  $fb = Graphics::Framebuffer->new('SPLASH' => 0, 'FB_DEVICE' => "/dev/fb0", 'IGNORE_X_WINDOWS' => TRUE, 'FONT_PATH' => "/home/pi/.fonts/");
  my ($width,$height) = $fb->screen_dimensions();
  if (($width != WIDTH) || ($height != HEIGHT)) {
    print_error("ERROR /dev/fb0 screen width/height: $width $height", "Display");
  }
  $fb->graphics_mode();
  clear_screen();
}

# Args: ref to hash with 1/0 for back/stop/play/pause/next (can't have play and pause), ref to ref of hash of areas
# returns the start of the boxes
sub print_transport_icons {
  my ($icons_ref, $areas_ref) = @_;
  my %args = %$icons_ref;
  delete $args{"pause"} if $args{"play"} == 1;
  foreach my $key (keys %{$$areas_ref}) {
    delete $$areas_ref->{$key};
  }
  my $box_width = 14 + 85 * $args{"back"} + 85 * $args{"next"} + 70 * $args{"play"} + 70 * $args{"pause"} + 70 * $args{"stop"};
  $fb->clip_reset();
  $fb->set_color($yellow);
  my $startx = WIDTH - $box_width - 20;
  my $x = $startx;
  my $y = 1048;
  $fb->box({
    'x'          => $x,
    'y'          => $y,
    'xx'         => $x + $box_width,
    'yy'         => $y + 80,
    'pixel_size' => 2
  });
  $x += 12;
  $y += 10;
  if ($args{"back"} == 1) {
    if (-e "images/jump-backwards.png") {
      $fb->blit_write($fb->load_image({
      'x'          => $x,
      'y'          => $y,
      'width'      => 75,
      'height'     => 60,
      'file'       => "images/jump-backwards.png",
      'convertalpha' => FALSE, 
      'preserve_transparency' => TRUE
      }));
    }
    $$areas_ref->{"back"} = {'x1' => $x, 'y1' => $y, 'x2' => $x + 75, 'y2' => $y + 60};
    $x += 85;
  }
  if ($args{"stop"} == 1) {
    if (-e "images/stop.png") {
      $fb->blit_write($fb->load_image({
      'x'          => $x,
      'y'          => $y,
      'width'      => 60,
      'height'     => 60,
      'file'       => "images/stop.png",
      'convertalpha' => FALSE, 
      'preserve_transparency' => TRUE
      }));
    }
    $$areas_ref->{"stop"} = {'x1' => $x, 'y1' => $y, 'x2' => $x + 60, 'y2' => $y + 60};
    $x += 70;
  }
  if ($args{"play"} == 1) {
    if (-e "images/play.png") {
      $fb->blit_write($fb->load_image({
      'x'          => $x,
      'y'          => $y,
      'width'      => 60,
      'height'     => 60,
      'file'       => "images/play.png",
      'convertalpha' => FALSE, 
      'preserve_transparency' => TRUE
      }));
    }
    $$areas_ref->{"play"} = {'x1' => $x, 'y1' => $y, 'x2' => $x + 60, 'y2' => $y + 60};
    $x += 70;
  }
  if ($args{"pause"} == 1) {
    if (-e "images/pause.png") {
      $fb->blit_write($fb->load_image({
      'x'          => $x,
      'y'          => $y,
      'width'      => 60,
      'height'     => 60,
      'file'       => "images/pause.png",
      'convertalpha' => FALSE, 
      'preserve_transparency' => TRUE
      }));
    }
    $$areas_ref->{"pause"} = {'x1' => $x, 'y1' => $y, 'x2' => $x + 60, 'y2' => $y + 60};
    $x += 70;
  }
  if ($args{"next"} == 1) {
    if (-e "images/jump-forwards.png") {
      $fb->blit_write($fb->load_image({
      'x'          => $x,
      'y'          => $y,
      'width'      => 75,
      'height'     => 60,
      'file'       => "images/jump-forwards.png",
      'convertalpha' => FALSE, 
      'preserve_transparency' => TRUE
      }));
    }
    $$areas_ref->{"next"} = {'x1' => $x, 'y1' => $y, 'x2' => $x + 75, 'y2' => $y + 60};
  }
  return $startx;
}

# args: image_path, alt_image_path, x, y, size, frame_flag
sub display_square_image {
  my ($image_path, $alt_image_path, $x, $y, $size, $frame_flag) = @_;
  $fb->clip_reset();
  if (! -e $image_path) {
    print_error("Unable to load thumbnail $image_path");
    $image_path = $alt_image_path;
  }
  my $scaled_path = "$image_path.scaled.$size.png";
  if (-e $scaled_path) {
    $image_path = $scaled_path;
  } else {
    my $image = Image::Resize->new($image_path);
    my $gd = $image->resize($size, $size);
    open(FH, '>', $scaled_path);
    print FH $gd->jpeg();
    close(FH);
    $image_path = $scaled_path;
  }
  $fb->blit_write($fb->load_image({
  'x'          => $x,
  'y'          => $y,
  'file'       => $image_path,
  'convertalpha' => FALSE, 
  'preserve_transparency' => TRUE
  }));
  if ($frame_flag) {
    $fb->set_color($white);
    $fb->box({                                # frame around icon
      'x'          => $x,
      'y'          => $y,
      'xx'         => $x + $size - 1,
      'yy'         => $y + $size - 1,
      'pixel_size' => 2
    });
    $size -= 4;
    $x += 2;
    $y += 2;
  }
}

sub clear_display_area {
  my $full = shift;
  $fb->set_color($black);
  if ($full) {
    $fb->rbox({
      'x'          => 0,
      'y'          => 120,
      'width'      => WIDTH,
      'height'     => 1046 - 120,
      'radius'     => 0,
      'pixel_size' => 1,
      'filled'     => 1
    });
  } else {
    $fb->rbox({
      'x'          => 0,
      'y'          => 120,
      'width'      => WIDTH,
      'height'     => 658 - 120,
      'radius'     => 0,
      'pixel_size' => 1,
      'filled'     => 1
    });
    display_dividing_line();
  }
}

sub clear_play_area {
  my $full = shift;
  $fb->set_color($black);
  if ($full) {
    $fb->rbox({
      'x'          => 0,
      'y'          => 659,
      'width'      => WIDTH,
      'height'     => HEIGHT - 122 - 659,
      'radius'     => 0,
      'pixel_size' => 1,
      'filled'     => 1
    });
    display_dividing_line();
  } else {
    $fb->rbox({
      'x'          => 0,
      'y'          => 1047,
      'width'      => WIDTH,
      'height'     => 111,
      'radius'     => 0,
      'pixel_size' => 1,
      'filled'     => 1
    });
  }
}

sub display_dividing_line {
  $fb->set_color($yellow);
  $fb->line({
    'x'           => 0,
    'y'           => 658,
    'xx'          => WIDTH,
    'yy'          => 658,
    'pixel_size'  => 2
  });
}

sub print_heading {
  my $heading = shift;
  if (-e "images/jellyfin.png") {
    my $icon_image = $fb->load_image({
        'x'          => 0,
        'y'          => 0,
        'scale_type' => 'min',
        'width'      => WIDTH,
        'height'     => 120,
        'file'       => "images/jellyfin.png",
        'convertalpha' => FALSE, 
        'preserve_transparency' => TRUE
    });
    $fb->blit_write($icon_image);
    $icon_image->{'x'} = WIDTH - 120;
    $fb->blit_write($icon_image);
  } else {
    print STDERR ("Unable to load images/jellyfin.png\n");
  }
  $fb->set_color($black);
  $fb->rbox({
    'x'          => 120,
    'y'          => 0,
    'width'      => WIDTH - 240,
    'height'     => 120,
    'radius'     => 0,
    'pixel_size' => 1,
    'filled'     => 1
  });
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'y'            => 120,
    'height'       => 50,
    'wscale'       => 1,                            # Scales the width.  1 is normal
    'face'         => 'Commissioner-Regular.ttf',
    'color'        => convert_colour_to_hex($screen_text_colour),
    'text'         => $heading,
    'center'       => CENTER_X
  }));
}

#----------------------------------------------------------------------------------------------------------------------
# args: 2 lines of text of what is playing, width of gap to print into
sub display_playing_text {
  my ($line1, $line2, $width) = @_;
  $fb->clip_reset();
  $fb->set_color($black);
  $fb->rbox({
    'x'          => 0,
    'y'          => 1048,
    'width'      => $width,
    'height'     => 110,
    'radius'     => 0,
    'pixel_size' => 1,
    'filled'     => 1
  });
  $fb->clip_set({
    'x'  => 10,
    'y'  => 900,
    'xx' => $width - 10,
    'yy' => 1200
  });
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'text'      => $line1,
    'x'         => $width / 2,
    'y'         => 1100,
    'height'    => 38,
    'center'    => CENTER_X,
    'face'      => 'Commissioner-Regular.ttf',
    'color'     => convert_colour_to_hex($screen_text_colour),
  }));
  my $tmp;
  my $h = 38;
  while (1) {
    $tmp = $fb->ttf_print({
      'bounding_box' => TRUE,
      'text'      => $line2,
      'x'         => $width / 2,
      'y'         => 1160,
      'height'    => $h,
      'center'    => CENTER_X,
      'face'      => 'Commissioner-Regular.ttf',
      'color'     => convert_colour_to_hex($screen_text_colour),
    });
    last if ($tmp->{"pwidth"} <= $width - 20);
    last if $h < 5;
    $h = int($h * 0.8);
  }
  $tmp->{'y'} = 1154 - int((38 - $h) / 2);
  $fb->ttf_print($tmp);
}

sub display_playing_nothing {
  my $full = shift;
  clear_play_area($full);
  $fb->clip_reset();
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'text'      => "Nothing playing",
    'x'         => WIDTH / 2,
    'y'         => ($full) ? 930 : 1130,
    'height'    => 38,
    'center'    => CENTER_X,
    'face'      => 'Commissioner-Regular.ttf',
    'color'     => convert_colour_to_hex($screen_text_colour),
  })) if $full;
}

#----------------------------------------------------------------------------------------------------------------------
sub rotate_cw {
  my $image_ref = shift;
  my $image = $$image_ref;
  my $angle = shift;
  $$image_ref = $fb->blit_transform({
    'blit_data' => $image,
    'rotate' => {'degrees' => - $angle}
  });
}

sub mirror {
  my $image_ref = shift;
  my $image = $$image_ref;
  my $dir = shift;
  $$image_ref = $fb->blit_transform({
    'blit_data' => $image,
    'flip' => $dir
  });
}

sub scale {
  my $image_ref = shift;
  my $image = $$image_ref;
  my $scale = (($$image{"width"} > 0) && ($$image{"height"} > 0)) ? min(WIDTH / $$image{"width"}, (HEIGHT - 400) / $$image{"height"}) : 1;
  #print STDERR ("$$image{'width'}:$$image{'height'} scale $scale\n");
  $$image_ref = $fb->blit_transform({
    'blit_data' => $image,
    'scale' => {
      'x'          => 0,
      'y'          => 0,
      'width'      => int($$image{"width"} * $scale),
      'height'     => int($$image{"height"} * $scale),
      'scale_type' => 'nonprop'
    }
  });
}

sub prepare_photo {
  my $filename = shift;
  if (-e $filename) {
    #print STDERR "Reading $filename\n";
    my $image = $fb->load_image({'file' => $filename, 'x' => 0, 'y' => 0});
    my $tags = $$image{"tags"};
    my $orientation = $$tags{"exif_orientation"};
    #print STDERR "Orientation = $orientation\n";
    my $ref = $orientations{$orientation};
    &$ref if $ref;
    scale(\$image);
    if ($$image{"width"} < WIDTH) {
      $$image{"x"} = int((WIDTH - $$image{"width"}) / 2);
    }
    if ($$image{"height"} < HEIGHT - 350) {      # (deliberately set high to catch edge cases)
      $$image{"y"} = 125 + int((HEIGHT - 360 - $$image{"height"}) / 2);
    }
    #print STDERR ($$image{"width"} . ":" . $$image{"height"} . ", " . $$image{"x"} . ":" . $$image{"y"} . "\n");
    return ($image, $filename);
  } else {
    return (undef, $filename);
  }
}

sub extract_file_details {
    my ($file_path) = @_;
    
    # Extract the filename and the directory path
    my $filename = fileparse($file_path);
    my $dir = dirname($file_path);
    
    # Remove the extension from the filename
    $filename =~ s/\.[^.]+$//;
    
    # Get the lowest level folder name
    my @dirs = split(/[\/\\]/, $dir);
    my $lowest_level_folder = $dirs[-1];
    
    return ($filename, $lowest_level_folder);
}

sub display_photo {
  my ($iref, $fname) = @_;
  if (defined $iref) {
    clear_display_area(1);
    $fb->clip_reset();
    $fb->blit_write($iref);
    my ($file, $folder) = extract_file_details($fname);
    $fb->ttf_print($fb->ttf_print({
      'bounding_box' => TRUE,
      'y'            => 150,
      'height'       => 20,
      'wscale'       => 1,                            # Scales the width.  1 is normal
      'face'         => 'Commissioner-Regular.ttf',
      'color'        => convert_colour_to_hex($screen_text_colour),
      'text'         => "Folder: $folder,  File: $file",
      'center'       => CENTER_X
    }));

  } else {
    clear_display_area(1);
    display_string("File not found at $fname");
  }
}

#----------------------------------------------------------------------------------------------------------------------
# Display a box with a letter inside it
sub display_boxed_letter {
  my ($letter, $x, $y) = @_;
  my $w = 75;
  my $h = 55;
  my $red = $$letter_fill_colour{"red"} * 0.7;
  my $blue = $$letter_fill_colour{"blue"} * 0.7;
  my $green = $$letter_fill_colour{"green"} * 0.7;
  $fb->box({
    'x'          => $x,
    'y'          => $y,
    'xx'         => $x + $w,
    'yy'         => $y + $h,
    'radius'     => 0,
    'pixel_size' => 1,
    'filled'     => 1,
    'gradient'    => {
        'direction' => 'horizontal',
        'colors'    => {
          'red'   => [$red, $red],
          'green' => [$green, $green],
          'blue'  => [$blue, $blue],
          'alpha' => [255, 255],
        }
    },
  });
  $fb->set_color($letter_fill_colour);
  $fb->rbox({
    'x'           => $x,
    'y'           => $y,
    'width'       => $w,
    'height'      => $h,
    'pixel_size'  => 2,
    'filled'      => 0

  });
  $fb->clip_set({
    'x'  => $x,
    'y'  => $y,
    'xx' => $x + $w,
    'yy' => $y + $h
  });
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'text'      => $letter,
    'y'         => $y + 70,
    'height'    => $h - 8,
    'face'      => 'Commissioner-Bold.ttf',
    'color'     => convert_colour_to_hex($letter_text_colour),
    'center'    => CENTER_X
  }));
  $fb->clip_reset();
}

# Args: ref to inputs hash (no x/y coords)
# Hash is updated with x/y coords of box
sub display_letter_grid {
  my ($ref) = @_;
  if ($ref) {
    my %input_hash = %$ref;
    my $gap_x = 27;
    my $gap_y = 40;
    my $i = 0;
    my $j = 0;
    foreach my $letter (sort keys %input_hash) {
      my $lx = 5 + $gap_x/2 + $i * ($gap_x + 75);
      my $ly = 120 + 30 + $gap_y/2 + $j * ($gap_y + 55);
      display_boxed_letter($letter, $lx, $ly);
      $i++;
      if ($i == 7) {
        $i = 0;
        $j++;
      }
      $input_hash{$letter}->{"x1"} = $lx;
      $input_hash{$letter}->{"y1"} = $ly;
      $input_hash{$letter}->{"x2"} = $lx + 75;
      $input_hash{$letter}->{"y2"} = $ly + 55;
      #print_error("Define input $lx $ly 50 37");
    }
  } else {
    # just say please wait
    display_string("Please wait ...", 0);
  }
}

# display grid of first letters of albums
# Args: ref to inputs hash (no x/y coords)
# Hash is updated with x/y coords of box
sub display_albums_top {
  display_letter_grid($_[0]);
}

# Display thumbnail with title and artist below
# Args: ref to hash 4, x, y
sub display_album_with_title {
  my ($ref, $sx, $sy) = @_;
  my %album = %$ref;
  my $fname = "thumbnail_cache/Items/" . $album{"id"} . "/Images/Primary.jpg";
  display_square_image($fname, "images/missing-image-icon.jpg", $sx + 30, $sy, 180, 0);
  my $title = $album{"title"};
  my $artist = $album{"artist"}->{"name"};
  $fb->clip_set({
    'x'  => $sx + 5,
    'y'  => $sy + 170,
    'xx' => $sx + 235,
    'yy' => $sy + 210
  });
  $fb->ttf_paragraph({
    'text'      => $title, 
    'x'         => $sx + 5,
    'y'         => $sy + 177, 
    'size'      => 24, 
    'color'     => convert_colour_to_hex($screen_text_colour), 
    'justify'   => 'center', 
    'face'      => 'Commissioner-Regular.ttf',
  });
  $fb->clip_set({
    'x'  => $sx + 5,
    'y'  => $sy + 200,
    'xx' => $sx + 235,
    'yy' => $sy + 258
  });
  $fb->ttf_paragraph({
    'text'      => $artist, 
    'x'         => $sx + 5,
    'y'         => $sy + 205, 
    'size'      => 24, 
    'color'     => convert_colour_to_hex($yellow), 
    'justify'   => 'center', 
    'face'      => 'Commissioner-Regular.ttf',
  });
  $fb->clip_reset();
}

# display grid of album icons
# Args: ref to array of ref to hash 4 (sorted by album name), start index into array, ref to inputs hash
# Grid of 3x2 album thumbnails with title/artist below
sub display_albums_with_letter {
  my ($ref, $start, $iref) = @_;
  my @albums = @$ref;
  foreach my $i (0 .. 5) {
    $ref = $albums[$start + $i];
    last unless ($ref);
    my $x = ($i - (($i > 2) ? 3 : 0)) * 240;
    my $y = (($i > 2 ) ? 400 : 150);
    display_album_with_title($ref, $x, $y);
    my $tracks_ref = $$ref{"tracks"};
    my $uid = $$ref{"artist"}->{"name"} . "/" . $$ref{"title"} . "/" . $tracks_ref->{(keys %$tracks_ref)[0]}->{"id"};             # construct unique id based on artist name / album title
    $$iref{$uid}->{"x1"} = $x;
    $$iref{$uid}->{"x2"} = $x + 240;
    $$iref{$uid}->{"y1"} = $y;
    $$iref{$uid}->{"y2"} = $y + 250;
  }
}

sub numeric_sort {
  return $a <=> $b;
}

# Args: ref to album, index to track being played
sub display_playing_album {
  my ($album_ref, $track, $full, $transport_areas_ref, $paused) = @_;
  clear_play_area($full);
  my $album_title = $$album_ref{"title"};
  my $album_thumb_url = $$album_ref{"id"};
  my $artist_ref = $$album_ref{"artist"};
  my $artist_name = $$artist_ref{"name"};
  my $tracks_ref = $$album_ref{"tracks"};
  my $track_title = $$tracks_ref{$track}->{"title"};
  my $album_thumb_path = "thumbnail_cache/Items/$album_thumb_url/Images/Primary.jpg";
  my @track_keys = sort numeric_sort keys %$tracks_ref;
  my $track_no = find_element_in_array($track, \@track_keys) + 1;
  my $width = print_transport_icons({"stop" => 1, "pause" => 1 - $paused, "play" => $paused, "next" => 1, "back" => 1}, $transport_areas_ref);
  display_play_screen_core($album_title, $album_thumb_path, $artist_name, $track_title, $track_no, scalar @track_keys, $full, 0, $width);
}

#----------------------------------------------------------------------------------------------------------------------
# Args: ref to inputs hash (no x/y coords)
# Hash is updated with x/y coords of box
sub display_artists_top {
  display_letter_grid($_[0]);
}

# Display thumbnail with artist below
# Args: ref to hash 2, x, y
sub display_artist_with_title {
  my ($ref, $sx, $sy) = @_;
  my %artist = %$ref;
  #print_error("artist thumbnail = " . $artist{"thumbnail"});
  my $fname = "thumbnail_cache/Items/" . $artist{"id"} . "/Images/Primary.jpg";
  display_square_image($fname, "images/missing-image-icon.jpg", $sx + 30, $sy, 180, 0);
  my $artist = $artist{"name"};
  $fb->clip_set({
    'x'  => $sx + 5,
    'y'  => $sy + 170,
    'xx' => $sx + 235,
    'yy' => $sy + 210
  });
  $fb->ttf_paragraph({
    'text'      => $artist, 
    'x'         => $sx + 5,
    'y'         => $sy + 177, 
    'size'      => 24, 
    'color'     => convert_colour_to_hex($screen_text_colour), 
    'justify'   => 'center', 
    'face'      => 'Commissioner-Regular.ttf',
  });
  $fb->clip_reset();
}

# Args: ref to hash 1 (artists name), start index into array, ref to inputs hash
# Grid of 3x2 album thumbnails with artist below
sub display_artists_with_letter {
  my ($aref, $start, $iref) = @_;
  my @artists = sort keys %$aref;
  foreach my $i (0 .. 5) {
    my $name = $artists[$start + $i];
    my $artist_ref = $aref->{$name};
    last unless ($artist_ref);
    my $x = ($i - (($i > 2) ? 3 : 0)) * 240;
    my $y = (($i > 2 ) ? 400 : 150);
    display_artist_with_title($artist_ref, $x, $y);
    $$iref{$name}->{"x1"} = $x;
    $$iref{$name}->{"x2"} = $x + 240;
    $$iref{$name}->{"y1"} = $y;
    $$iref{$name}->{"y2"} = $y + 250;
  }
}

# display grid of album icons
# Args: ref to hash 2, start index into array, ref to inputs hash
# Grid of 3x2 album thumbnails with title/artist below
sub display_artist_albums_with_letter {
  my ($aref, $start, $iref) = @_;
  my @album_refs;
  foreach my $key (keys %{$aref->{"albums"}}) {
    push(@album_refs, {"key" => $key, "ref" => $aref->{"albums"}->{$key}})
  }
  @album_refs = sort album_key_sort @album_refs;
  print_error("number of albums found: " . scalar @album_refs);
  foreach my $i (0 .. 5) {
    my $ref = $album_refs[$start + $i]->{"ref"};
    last unless ($ref);
    my $x = ($i - (($i > 2) ? 3 : 0)) * 240;
    my $y = (($i > 2 ) ? 400 : 150);
    display_album_with_title($ref, $x, $y);
    my $tracks_ref = $$ref{"tracks"};
    my $uid = $$ref{"artist"}->{"name"} . "/" . $$ref{"title"} . "/" . $tracks_ref->{(keys %$tracks_ref)[0]}->{"id"};             # construct unique id based on artist name / album title
    $$iref{$uid}->{"x1"} = $x;
    $$iref{$uid}->{"x2"} = $x + 240;
    $$iref{$uid}->{"y1"} = $y;
    $$iref{$uid}->{"y2"} = $y + 250;
  }
}

sub album_key_sort {
  return remove_leading_article($a->{"ref"}->{"title"}) cmp remove_leading_article($b->{"ref"}->{"title"});
}

#----------------------------------------------------------------------------------------------------------------------
# Display thumbnail with title below
# Args: title, id of playlist, x, y
sub display_playlist_item {
  my ($title, $id, $sx, $sy) = @_;
  display_square_image("thumbnail_cache/Items/" . $id . "/Images/Primary.jpg", "images/missing-image-icon.jpg", $sx + 60, $sy, 120, 0);
  $fb->clip_set({
    'x'  => $sx + 5,
    'y'  => $sy + 130,
    'xx' => $sx + 235,
    'yy' => $sy + 180
  });
  $fb->ttf_paragraph({
    'text'      => $title, 
    'x'         => $sx + 5,
    'y'         => $sy + 130, 
    'size'      => 25,
    'color'     => convert_colour_to_hex($screen_text_colour), 
    'justify'   => 'center', 
    'face'      => 'Commissioner-Regular.ttf',
  });
  $fb->clip_reset();
}

# Args: ref to inputs hash (no x/y coords)
# Hash is updated with x/y coords of box
sub display_playlists_top {
  my ($ref_input, $ref_lists, $index) = @_;
  sub sort_playlists_by_name { return $$ref_lists{$a}->{"name"} cmp $$ref_lists{$b}->{"name"}; }
  clear_display_area(0);
  if ($ref_input && $ref_lists) {
    my %input_hash = %$ref_input;
    my $wx = 240;
    my $wy = 192;
    my $i = 0;
    my $j = 0;
    my $cnt = -1;
    foreach my $id (sort sort_playlists_by_name keys %input_hash) {             # display playlists alphabetically
      $cnt++;
      next if $cnt < $index;
      last if $cnt > $index + 5;
      my $title = $$ref_lists{$id}->{"name"};
      my $lx = $i * $wx;
      my $ly = $j * $wy + 190;
      display_playlist_item($title, $id, $lx, $ly);
      $i++;
      if ($i == 3) {
        $i = 0;
        $j++;
      }
      $input_hash{$id}->{"x1"} = $lx;
      $input_hash{$id}->{"y1"} = $ly;
      $input_hash{$id}->{"x2"} = $lx + $wx;
      $input_hash{$id}->{"y2"} = $ly + $wy;
      #print_error("Define input $lx $ly 50 37");
    }
  } else {
    display_string("Please wait ...", 0);
  }
}

# Args: playlist id, ref to playlists, index to track being played
sub display_playing_playlist {
  my ($id, $playlists_ref, $track_no, $full, $transport_areas_ref, $paused) = @_;
  my %playlists = %$playlists_ref;
  my $tracks_ref = $playlists{$id}->{"tracks"};
  my $title = $playlists{$id}->{"name"};
  my $track_id = $tracks_ref->[$track_no]->{"id"};
  my $album_id = $tracks_ref->[$track_no]->{"album_id"};
  print_error("Playing from playlist $title, track number $track_no");
  my $tracks_thumb_path = "thumbnail_cache/Items/$track_id/Images/Primary.jpg";
  $tracks_thumb_path = "thumbnail_cache/Items/$album_id/Images/Primary.jpg" if (! -e $tracks_thumb_path);      # use album art if no track art
  #print_error("Track thumb path $tracks_thumb_path");
  my $artist_name = $tracks_ref->[$track_no]->{"artist_name"};
  my $track_title = $tracks_ref->[$track_no]->{"track_title"};
  clear_play_area($full);
  my $icons_x = print_transport_icons({"stop" => 1, "pause" => 1 - $paused, "play" => $paused, "next" => 1}, $transport_areas_ref);
  display_play_screen_core($title, $tracks_thumb_path, $artist_name, $track_title, 0, 0, $full, 1, $icons_x - 10);
}

#----------------------------------------------------------------------------------------------------------------------
# $title is either album title or playlist title or radio name
# $playlist_flag is 1 for playlist/radio, 0 for album
sub display_play_screen_core {
  my ($title, $thumb_path, $artist_name, $track_title, $track_number, $tracks_total, $full, $playlist_flag, $label_width) = @_;
  display_playing_text("Playing:", "$title playlist", $label_width) if $playlist_flag;
  display_playing_text("Track $track_number of $tracks_total", $track_title, $label_width) if !$playlist_flag;
  return if !$full;
  display_square_image($thumb_path, "images/missing-music-group-icon.png", 0, 680, 300, 1);
  $fb->clip_set({
    'x'  => 340,
    'y'  => 680,
    'xx' => WIDTH,
    'yy' => 850
  });
  my $str = ($playlist_flag) ? $track_title : $title;
  $fb->ttf_paragraph({
    'text'      => remove_trailing_squares($str), 
    'x'         => 340,
    'y'         => 680, 
    'size'      => 40, 
    'color'     => convert_colour_to_hex($screen_text_colour), 
    'justify'   => 'left', 
    'face'      => 'Commissioner-Bold.ttf',
  });
  my $r = find_last_row($fb->blit_read({
    'x'      => 340,
    'y'      => 680,
    'width'  => WIDTH - 340,
    'height' => 850 - 680
  }));
  $fb->blit_move({
    'x'      => 340,
    'y'      => 680,
    'width'  => WIDTH - 340,
    'height' => 850 - 680,
    'x_dest' => 340,
    'y_dest' => 860 - $r - 20
  });
  $fb->clip_reset();
  $fb->set_color($black);
  $fb->rbox({
    'x'          => 340,
    'y'          => 860,
    'width'      => WIDTH - 340,
    'height'     => 1045 - 860,
    'radius'     => 0,
    'pixel_size' => 1,
    'filled'     => 1
  });
  $fb->ttf_paragraph({
    'text'      => "by $artist_name", 
    'x'         => 340,
    'y'         => 860, 
    'size'      => 40, 
    'color'     => convert_colour_to_hex($yellow), 
    'justify'   => 'left', 
    'face'      => 'Commissioner-Regular.ttf',
  });
}

#----------------------------------------------------------------------------------------------------------------------
# Display small icon with title below
# Args: title, url of icon, x, y
sub display_radio_item {
  my ($title, $fname, $sx, $sy) = @_;
  #print_error("display radio item: $title, $fname, $sx $sy");
  display_square_image("images/radio-icons/$fname", "images/missing-image-icon.jpg", $sx + 60, $sy, 120, 0);
  $fb->clip_set({
    'x'  => $sx + 5,
    'y'  => $sy + 130,
    'xx' => $sx + 235,
    'yy' => $sy + 180
  });
  $fb->ttf_paragraph({
    'text'      => $title, 
    'x'         => $sx + 5,
    'y'         => $sy + 130, 
    'size'      => 30, 
    'color'     => convert_colour_to_hex($screen_text_colour), 
    'justify'   => 'center', 
    'face'      => 'Commissioner-Regular.ttf',
  });
  $fb->clip_reset();
}

# Args: ref to inputs hash (no x/y coords), ref to radio stations, index
# Hash is updated with x/y coords of box
sub display_radio_top {
  my ($ref_input, $ref_lists, $index) = @_;
  clear_display_area(0);
  my %input_hash = %$ref_input;
  my $wx = 240;
  my $wy = 240;
  my $i = 0;
  my $j = 0;
  my $cnt = -1;
  foreach my $label (sort keys %input_hash) {
    $cnt++;
    next if $cnt < $index;
    last if $cnt > $index + 5;
    my $lx = $i * $wx;
    my $ly = $j * $wy + 190;
    display_radio_item($ref_lists->{$label}->{"name"}, $ref_lists->{$label}->{"thumbnail"}, $lx, $ly);
    $i++;
    if ($i == 3) {
      $i = 0;
      $j++;
    }
    $input_hash{$label}->{"x1"} = $lx;
    $input_hash{$label}->{"y1"} = $ly;
    $input_hash{$label}->{"x2"} = $lx + $wx;
    $input_hash{$label}->{"y2"} = $ly + $wy;
  }
}

# Args: radio label, ref to stations, full(1)/minimal
# we have 480 x 260 to play with
sub display_playing_radio {
  my ($label, $radio_stations_ref, $full, $transport_areas_ref) = @_;
  print_error("Playing radio $label");
  clear_play_area($full);
  print_transport_icons({"stop" => 1}, $transport_areas_ref);
  $fb->clip_reset();
  if ($full) {
    my $fname = $radio_stations_ref->{$label}->{"icon"};
    $fname = "images/radio-icons/$fname";
    if (-e $fname) {
      my $image = $fb->load_image({
        'y'          => 680,
        'x'          => 0,
        'width'      => WIDTH,
        'height'     => 348,
        'file'       => $fname,
        'convertalpha' => FALSE, 
        'preserve_transparency' => TRUE
      });
      $image->{'x'} = (WIDTH - $image->{'width'}) / 2;
      $image->{'y'} = 680 + (348 - $image->{'height'}) / 2;
      $fb->blit_write($image);
    }
  } else {
    display_playing_text("Playing: ", $radio_stations_ref->{$label}->{"name"}, 610);
  }
}

#----------------------------------------------------------------------------------------------------------------------
# display semi-circular pie chart with value in the centre
sub draw_slice {
  my ($part, $x, $y, $size, $title) = @_;
  my $large = ($size eq "large");
  my $radius = ($large) ? 100 : 40;
  $fb->clip_reset();
  $fb->set_color((defined $part) ? $dark_green : $grey);
  $fb->draw_arc({
    'x'             => $x,
    'y'             => $y,
    'radius'        => $radius,
    'start_degrees' => -90, # Compass coordinates
    'end_degrees'   => 90,
    'granularity'   => 0.05,
    'mode'          => 1
  });
  $fb->set_color((defined $part) ? $pale_yellow : $grey);
  $fb->draw_arc({
    'x'             => $x,
    'y'             => $y,
    'radius'        => $radius,
    'start_degrees' => -90 + 1.8 * $part,
    'end_degrees'   => 90,
    'granularity'   => 0.05,
    'mode'          => 1
  });
  $fb->set_color($red);         # for some reason, draw_arc doesn't like black so have to draw in red then fill red with black
  $fb->draw_arc({
    'x'             => $x,
    'y'             => $y,
    'radius'        => $radius * (($large) ? 0.6 : 0.5),
    'start_degrees' => -90, # Compass coordinates
    'end_degrees'   => 90,
    'granularity'   => 0.05,
    'mode'          => 1
  });
  $fb->clip_set({
    'x'  => $x - $radius - 1,
    'y'  => $y - $radius - 1,
    'xx' => $x + $radius + 1,
    'yy' => $y + 1
  });
  $fb->replace_color({
    'old' => $red,
    'new' => $black
  });
  $fb->clip_set({
    'x'  => $x - (($large) ? 110 : 70),
    'y'  => $y,
    'xx' => $x + (($large) ? 110 : 70),
    'yy' => $y + 100
  });
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'y'            => $y + (($large) ? 47 : 35),
    'height'       => ($large) ? 30 : 20,
    'wscale'       => 1.1,                            # Scales the width.  1 is normal
    'face'         => 'Commissioner-SemiBold.ttf',
    'color'        => convert_colour_to_hex($screen_text_colour),
    'text'         => $title,
    'center'       => CENTER_X
  }));
  if ($large) {
    $fb->clip_set({
      'x'  => $x - 100,
      'y'  => $y - 100,
      'xx' => $x + 110,
      'yy' => $y
    });
    $fb->ttf_print($fb->ttf_print({
      'bounding_box' => TRUE,
      'y'            => $y + 14,
      'height'       => 35,
      'wscale'       => 1,                            # Scales the width.  1 is normal
      'face'         => 'Commissioner-Bold.ttf',
      'color'        => convert_colour_to_hex($screen_text_colour),
      'text'         => sprintf("%.0f%", $part),
      'center'       => CENTER_X
    })) if defined $part;
  }
}

# display HA parameter and value
sub display_ha_param {
  my ($x, $y, $text1, $text2) = @_;
  $fb->clip_reset();
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'y'            => $y,
    'x'            => $x,
    'height'       => 35,
    'wscale'       => 1,                            # Scales the width.  1 is normal
    'face'         => 'Commissioner-Regular.ttf',
    'color'        => convert_colour_to_hex($screen_text_colour),
    'text'         => "$text1:",
  }));
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'y'            => $y,
    'x'            => $x + 240,
    'height'       => 35,
    'wscale'       => 1,                            # Scales the width.  1 is normal
    'face'         => 'Commissioner-Regular.ttf',
    'color'        => convert_colour_to_hex($screen_text_colour),
    'text'         => $text2,
  }));
}

# display HA section title
sub display_ha_title {
  my ($y, $title) = @_;
  $fb->set_color($screen_text_colour);
  $fb->clip_set({
    'x'  => 10,
    'y'  => 0,
    'xx' => 230,
    'yy' => HEIGHT
  });
  $fb->ttf_print($fb->ttf_print({
    'bounding_box' => TRUE,
    'y'            => $y,
    'height'       => 50,
    'wscale'       => 1,                            # Scales the width.  1 is normal
    'face'         => 'Commissioner-Bold.ttf',
    'color'        => convert_colour_to_hex($screen_text_colour),
    'text'         => $title,
    'center'       => CENTER_X
  }));
}

sub changed {
  my $ref = shift;
  my @vals = @_;
  my $i = 0;
  my $changed = 0;
  foreach my $val (@vals) {
    if (defined $val) {                     # if we have a new value
      if (! defined $ref->[$i]) {           # if no old value
        $changed = 1;
        $ref->[$i] = $val;
      } else {                              # if we have an old value
        if ($ref->[$i] ne $val) {           # if new different to old (using string comp)
          $changed = 1;
          $ref->[$i] = $val;
        }
      }
    }
    $i++;
  }
  return $changed;
}

# solar parameters
sub display_solar {
  my ($data_ref, $force_display) = @_;
  state @old_values;
  my $vale = $data_ref->{return_solar_exported()};
  my $valbp = $data_ref->{return_solar_bat_power()};
  my $valsp = $data_ref->{return_solar_power()};
  if (changed(\@old_values, $vale, $valbp, $valsp) || $force_display) {
    $fb->clip_reset();
    $fb->set_color($black);
    $fb->rbox({                  # clear the solar area
      'x'          => 0,
      'y'          => 120,
      'width'      => WIDTH,
      'height'     => 340 - 120,
      'radius'     => 0,
      'pixel_size' => 1,
      'filled'     => 1
    });
    draw_slice($data_ref->{return_solar_battery()}, 120, 290, "large", "Battery");
    display_ha_title(200, "Solar");
    my $valc;
    if (defined($valsp) && defined($valbp) && defined($vale)) {
      $valc = $valsp - $valbp - $vale;
      $valc = format_number($valc) . "W";
    }
    $valsp = format_number($valsp) . "W" if defined $valsp;
    display_ha_param(280, 210, "Generating", $valsp);
    if ($vale < 0) {
      $vale = format_number(-$vale) . "W" if defined $vale;
      display_ha_param(280, 265, "Importing", $vale);
    } else {
      $vale = format_number($vale) . "W" if defined $vale;
      display_ha_param(280, 265, "Exporting", $vale);
    }
    display_ha_param(280, 320, "Consuming", $valc);
    $fb->clip_reset();
    $fb->set_color($yellow);
    $fb->line({
      'x'           => 0,
      'y'           => 340,
      'xx'          => WIDTH,
      'yy'          => 340,
      'pixel_size'  => 2
    });
  }
}

# car parameters
sub display_car {
  my ($data_ref, $force_display) = @_;
  state @old_values;
  my $valr = $data_ref->{return_car_range()};
  my $valct = $data_ref->{return_car_time()};
  my $valpi = $data_ref->{return_car_connected()};
  if (changed(\@old_values, $valr, $valct, $valpi) || $force_display) {
    $fb->clip_reset();
    $fb->set_color($black);
    $fb->rbox({                          # clear the car area
      'x'          => 0,
      'y'          => 342,
      'width'      => WIDTH,
      'height'     => 559 - 342,
      'radius'     => 0,
      'pixel_size' => 1,
      'filled'     => 1
    });
    draw_slice($data_ref->{return_car_battery()}, 120, 510, "large", "Battery");
    display_ha_title(420, "Car");
    $valr = int($valr * 5 / 8) . " miles" if defined $valr;
    $valct = sprintf("%.1f hours") if defined $valct;
    $valpi = ($valpi eq "off") ? "No" : "Yes" if defined $valpi;
    display_ha_param(280, 430, "Range", $valr);
    display_ha_param(280, 485, "Charge time", $valct);
    display_ha_param(280, 540, "Plugged in", $valpi);
    $fb->set_color($yellow);
    $fb->line({
      'x'           => 0,
      'y'           => 340,
      'xx'          => WIDTH,
      'yy'          => 340,
      'pixel_size'  => 2
    });
    $fb->line({
      'x'           => 0,
      'y'           => 560,
      'xx'          => WIDTH,
      'yy'          => 560,
      'pixel_size'  => 2
    });
  }
}

# printer ink statuses
sub display_printer {
  my ($data_ref, $force_display) = @_;
  state @old_values;
  my $valm = $data_ref->{return_ink_magenta()};
  my $valc = $data_ref->{return_ink_cyan()};
  my $valy = $data_ref->{return_ink_yellow()};
  my $valb = $data_ref->{return_ink_black()};
  if (changed(\@old_values, $valm, $valc, $valy, $valb) || $force_display) {
    $fb->clip_reset();
    $fb->set_color($black);
    $fb->rbox({                    #clear the printer area
      'x'          => 0,
      'y'          => 560,
      'width'      => WIDTH,
      'height'     => 657 - 560,
      'radius'     => 0,
      'pixel_size' => 1,
      'filled'     => 1
    });
    display_ha_title(650, "Printer");
    draw_slice($data_ref->{return_ink_magenta()}, 270, 615, "small", "Magenta");
    draw_slice($data_ref->{return_ink_cyan()}, 400, 615, "small", "Cyan");
    draw_slice($data_ref->{return_ink_yellow()}, 530, 615, "small", "Yellow");
    draw_slice($data_ref->{return_ink_black()}, 660, 615, "small", "Black");
    $fb->clip_reset();
    $fb->set_color($yellow);
    $fb->line({
      'x'           => 0,
      'y'           => 560,
      'xx'          => WIDTH,
      'yy'          => 560,
      'pixel_size'  => 2
    });
  }
}

sub display_home_assistant {
  my ($data_ref, $force_display) = @_;
  #print_error("display home assistant");
  display_solar($data_ref, $force_display);
  display_car($data_ref, $force_display);
  display_printer($data_ref, $force_display);
}

1;
