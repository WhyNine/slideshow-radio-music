package Utils;

our @EXPORT = qw ( print_error print_hash_params find_element_in_array remove_trailing_squares remove_leading_article midnight turn_display_off turn_display_on 
  turn_display_dim format_number seconds_until_midnight);
use base qw(Exporter);

use strict;
use Time::Local;

use lib "/home/pi/display";

sub format_number {
  my $val = shift;
  $val = sprintf("%.0f", $val);
  while ($val =~ s/(.*\d)(\d\d\d)/$1\,$2/g){};
  return $val;
}

sub print_error {
  my $str = shift;
  print STDERR localtime() . " $str\n";
}

sub print_hash_params {
  my $ref = shift;
  my $str;
  foreach my $k (keys %$ref) {
    $str .= "$k = " . $ref->{$k} . ", ";
  }
  print_error($str);
}

sub find_element_in_array {
  my ($e, $ref) = @_;
  for my $i (0 .. scalar @$ref - 1) {
    return $i if ($e eq $$ref[$i]);
  }
  return -1;
}

# remove square brackets from end of string
sub remove_trailing_squares {
  my $text = shift;
  return $text unless substr($text, length($text) - 1, 1) eq "]";
  my $lb = rindex($text, "[");
  return $text unless $lb;
  my @split = split('\[', $text);
  return $split[0];
}

sub remove_leading_article {
  my $text = shift;
  return substr($text, 4) if ($text =~ m/^The /);
  return substr($text, 2) if ($text =~ m/^A /);
  return $text;
}

sub seconds_until_midnight {
    my $now = timelocal(localtime());
    return midnight() - $now;
}

sub midnight {
  my ($sec, $min, $hour, $mday, $mon, $year) = localtime();
  # Calculate the last day of the current month
  my @last_day_of_month = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
  # Adjust for leap years
  if (($year + 1900) % 4 == 0 && ($year + 1900) % 100 != 0 || ($year + 1900) % 400 == 0) {
    $last_day_of_month[1] = 29;
  }
  if ($mday == $last_day_of_month[$mon]) {
    # It's the last day of the month, roll over to the first day of the next month
    $mon = ($mon + 1) % 12;
    $mday = 1;
    if ($mon == 0) {
        $year++;
    }
  } else {
    $mday++;
  }
  my $midnight = timelocal(0, 0, 0, $mday, $mon, $year);
  return $midnight;
}

sub turn_display_off {
  `sudo echo 0 > /sys/class/backlight/10-0045/brightness`;
}

sub turn_display_on {
  `sudo echo 2 > /sys/class/backlight/10-0045/brightness`;
}

sub turn_display_dim {
  `sudo echo 1 > /sys/class/backlight/10-0045/brightness`;
}

1;
