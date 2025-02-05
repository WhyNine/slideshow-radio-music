package Audio;

use strict;
use v5.28;

our @EXPORT = qw ( audio_play audio_stop audio_init audio_state player_poll audio_pause_play );
use base qw(Exporter);

use lib "/home/pi/display";

use Utils;
use UserDetails qw ( $jellyfin_url );

use Audio::Play::MPG123;
use File::Basename;

my $player;
my $poll_event_ref;
my $vlc_playing = 0;

sub player_poll {
  $player->poll(0) if $player;
}

# 0 = idle, 2 = playing
sub audio_state {
  #print_error("audio state = " . $player->state());
  return 2 if $vlc_playing;
  return $player->state() if $player;
  return 0;
}

sub audio_init {
  $poll_event_ref = shift;
  print_error("audio init");
  my $pulse = `pulseaudio --start`;
  new_player();
}

sub new_player {
  $player = new Audio::Play::MPG123;
  print_error("audio initialised ok") if $player;
  print_error("audio initialised fail") unless $player;
}

sub audio_stop {
  print_error("audio stop");
  $player->stop() if $player;
  $$poll_event_ref->stop() if $poll_event_ref;
}

# Note: Some folders include utf8 chars which aren't handled well by mpg123, so change to folder then play file to get round it
# when playing a network radio stream, sub does not return until vlc process killed externally
sub audio_play {
  my $path = shift;
  #print_error("audio play");
  audio_stop();
  new_player();
  if ($path =~ /^http/ and $path !~ /$jellyfin_url/) {
    print_error("playing stream audio from $path");
    $vlc_playing = 1;
    my $vlc = `cvlc --no-video $path`;
    $vlc_playing = 0;
  } else {
    return unless $player;
    if ($path =~ /^http/) {
      if (!$player->load($path)) {
        print_error("Unable to start playing track at $path");
      } else {
        print_error("Started playing music");
      }
    } else {
      my ($filename, $folder, $suffix) = fileparse($path);
      chdir $folder;
      #print_error($folder);
      if (!$player->load($filename)) {
        print_error("Unable to start playing track at $path");
      } else {
        print_error("Started playing music");
      }
    }
    $$poll_event_ref->start();
  }
}

sub audio_pause_play {
  print_error("audio play/pause");
  return unless $player;
  $player->pause();
}


1;
