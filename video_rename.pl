#!/usr/bin/perl

use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/lib";

use Getopt::Long;
use HTML::TableExtract;
use LWP::Simple qw($ua getstore get);
use File::Slurp;
use File::Copy;
use File::Path;
use File::Basename;
use YAML qw(DumpFile LoadFile);
use IMDB::Film;
use FindBin;
use Term::ReadLine;
use File::Find;
use String::Approx;
use Cwd 'abs_path';
use Text::Balanced qw(extract_bracketed);
use VideoName;

my $shows = LoadFile("$FindBin::Bin/video_rename.cfg");
my %shows = %$shows;

for my $show_name (keys %shows) {
  $shows{$show_name}->{show_name} = $show_name;
}
#----------------------------------------------------------------------

my $verbose;
my $force;
my $staging_default;
my $show_hint;
GetOptions('v|verbose!' => \$verbose,
           'force!' => \$force,
           'staging!' => \$staging_default,
           'show' => \$show_hint,
          );

my $term = Term::ReadLine->new('console_app');
$term->Attribs->ornaments(0);

my @search_dirs = @ARGV;
unless (@search_dirs) {
    @search_dirs = ('.');
}
find( {
       wanted => sub {
           if (-f $File::Find::name && $File::Find::name =~ /\.(avi|divx|mov|mpeg|mpg|mp4|ogm|mkv|rmvb|flv|wmv)$/i) {
               rename_episode(filename => abs_path($File::Find::name),
                              show_hint => $show_hint,
                             );
           }
       },
       preprocess => sub {
           return sort @_;
       },
       no_chdir => 1,
      },
      @search_dirs);

DumpFile("$FindBin::Bin/video_rename.cfg", \%shows);

#----------------------------------------------------------------------

sub rename_episode {
    my(%params) = @_;
    my $filename = $params{filename};
    my $show_hint = $params{show_hint};

    my $staging_option = $staging_default;

    print "-" x 70 . "\n";
    my $correct = 'start'; 
    my $overwrite_allowed = 0;
    my $new_filename;
    my $multiple_matches = [];
    $new_filename = get_final_location(filename => $filename,
                                       staging => $staging_option,
                                       show_hint => $show_hint,
                                       multiple_matches => $multiple_matches,
                                      );
    unless ($new_filename) {
        print "Can't match: $filename\n";
        return;
    }
    while ($correct && $correct ne 'y') {

        if ($new_filename eq $filename) {
            if ($verbose) {
                print "Already in correct location!\n";
            }
            return;
        }

        print "Old filename: $filename\nNew filename: $new_filename\n";
        if (-e $new_filename) {
            print "Spot occupied -- must specify overwrite\n";
            print "Old filesize: " . (-s $filename) . "\n";
            print "New filesize: " . (-s $new_filename) . "\n";
        }
    
        $correct = $term->readline("\nIs this correct? (Y/n/s/o/e/q/t) ");
        if ($correct eq 'q') {
            DumpFile("$FindBin::Bin/video_rename.cfg", \%shows);
            exit;
        }
        if ($correct eq 'o') {
            $overwrite_allowed = 1;
        }
        if ($correct eq 's') {
            $staging_option = 1;
            $new_filename = get_final_location(filename => $filename,
                                               staging => $staging_option,
                                              );
        }
        if ($correct eq 't') {
            $new_filename = get_final_location(filename => $filename,
                                               get_episode_from_title => 1,
                                              );
        }
        if ($correct eq 'n') {
            return;
        }
        if ($correct eq 'e') {
            $new_filename = $term->readline('New filename: ', $new_filename);
        }
    }
    if (!-e $new_filename || $overwrite_allowed) {
        print "$filename => $new_filename\n";
        mkpath(dirname($new_filename));
        move($filename, $new_filename);
    }
}

#----------------------------------------------------------------------

sub get_final_location {
  my(%params) = @_;
  my $filename = $params{filename};

  my $show;
  if ($params{show_hint}) {
    $show = get_show_from_filename($params{show_hint});
  }
  else {
    $show = get_show_from_filename($filename);
  }

  if (!$show) {
      print "Can't find a matching show for $filename\n";
      $show = search_for_missing_show();
      if (!$show) {
          return;
      }
  }

  my($season, $episode_num, $episode_part);

  if ($filename =~ m|/Season (\d+)/|) {
    $season = $1;
  }

  if ($filename =~ /(?:so?|season )(\d+)[-. _]*ep?\.?\s*(\d+)/i) {
    $season = $1;
    $episode_num = $2;
  } 
  elsif ($filename =~ /\[(\d+)[-. _x](\d+)\]/i) {
    $season = $1;
    $episode_num = $2;
  } 
  elsif ($filename =~ /(\d+)x(\d+)([ab])?/) {
    $season = $1;
    $episode_num = $2;
    $episode_part = $3;
  } elsif ($filename =~ /\.(0?\d)(\d\d)([ab])?\./) {
    $season = $1;
    $season = '1' if $season eq '0';
    $episode_num = $2;
    $episode_part = $3;
  }
  elsif ($filename =~ /(\d{2,3})([ab])?/) {
    $episode_num = $1;
    $season ||= 1;
    $episode_part = $2;
    if (!$show->{no_season_num} && $episode_num =~ s/^(\d)(\d\d)$/$2/) {
      $season = $1;
    }
    if ($show->{no_hundreds}) {
      $episode_num = $episode_num % 100;
    }
  }
  elsif ($filename =~ /-\s+(\d+)\s+-/) {
    $episode_num = $1;
    $season = 1;
  }

  if ($params{get_episode_from_title} || $show->{get_episode_from_title}) {
      my($new_season, $new_episode_num) = get_episode_from_title(show => $show,
                                                                 filename => $filename,
                                                                );
      if ($new_season && defined $new_episode_num) {
          $season = $new_season;
          $episode_num = $new_episode_num;
      }
  }
  return '' unless (defined $episode_num);

  $season =~ s/^0//;
  $episode_num =~ s/^0*([^0])/$1/;

  my($suffix) = ($filename =~ /(\.[^.]*)$/);
  my $pr_episode_num;
  if ($show->{no_season_num}) {
    my $digits = ($show->{max_episode_num} ? length($show->{max_episode_num}) : 2);
    $pr_episode_num = sprintf("%${digits}d", $episode_num);
  }
  else {
    $pr_episode_num = sprintf("%2.2d", $episode_num);
  }
  $pr_episode_num .= $episode_part if $episode_part;
  unless ($show->{no_season_num}) {
    $pr_episode_num = "${season}x$pr_episode_num";
  }
  my $new_name;
  if ($show->{url} && $show->{url} eq 'none') {
    $new_name = "$show->{show_name} - $pr_episode_num" . $suffix;
  }
  else {
    $new_name = "$show->{show_name} - $pr_episode_num - " . old_get_title($show, $season, $episode_num, $episode_part) . $suffix;
  }

  $new_name =~ s|/|-|g;
  my $new_path;
  if ($show->{final_disk}) {
      $new_path = $show->{final_disk};
  }
  else {
      $new_path = '/a1/video';
  }
  if ($params{staging}) {
      $new_path .= '/staging';
  }

  $new_path .= '/' . ($show->{video_type} || 'video2') . '/tv';

  $new_path .= "/$show->{show_name}";
  if (!$show->{no_season_num}) {
      if ($season eq 'S') {
          $new_path .= "/Specials";
      }
      else {
          $new_path .= "/Season $season";
      }
  }
  $new_path .= "/$new_name";

  return $new_path;
}

#----------------------------------------------------------------------

sub old_get_title {
  my($show, $season, $episode_num, $episode_part) = @_;

  if ($show->{imdb} || $show->{wiki}) {
      return get_title(show => $show, 
                       season =>  $season,
                       episode => $episode_num);
  }
  
  my $content = get_titles_from_cache($show, $season);

  my $seek_episode;
  if ($show->{no_season_num} && !$show->{season_num_in_source}) {
    $seek_episode = sprintf("%d", $episode_num);
  }
  else {
    $seek_episode = $season . 'x' . sprintf("%2.2d", $episode_num);
  }

  if ($show->{data_source} && $show->{data_source} eq 'pattern_match') {
    return get_title_from_pattern_match(show => $show, 
                                        seek_episode => $seek_episode,
                                        episode_part => $episode_part,
                                        content => $content);
  }
  elsif ($show->{data_source} && $show->{data_source} eq 'pattern_match2') {
    return get_title_from_pattern_match2(show => $show, 
                                        seek_episode => $seek_episode,
                                        episode_part => $episode_part,
                                        content => $content);
  }
  else {
    return get_title_from_table(show => $show, 
                                seek_episode => $seek_episode,
                                episode_part => $episode_part,
                                content => $content);
  }
}

#----------------------------------------------------------------------

sub get_title_from_pattern_match {
  my(%params) = @_;
  my $show = $params{show};
  my $episode_part = $params{episode_part};
  my $content = $params{content};
  my $seek_episode = $params{seek_episode};

  my $last_episode_num = 0;
  my $increase_episode_amount = 0;
  while ($content =~ /^($show->{episode_line_pattern}.*?)$/gm) {
    my $episode_line = $1;
    my @episode_line_parts = split(/$show->{episode_line_delimiter}/, $episode_line);
    my $line_episode_num = $episode_line_parts[$show->{ep_num_column}];
    next unless ($line_episode_num =~ /^[\s\d]+$/);

    if ($line_episode_num == 1) {
      $increase_episode_amount = $last_episode_num;
    }
    $line_episode_num += $increase_episode_amount;

    if ($line_episode_num == $seek_episode) {
      my $episode_name = $episode_line_parts[$show->{name_column}];
      return clean_episode_name($episode_name);
    }
    $last_episode_num = $line_episode_num;
  }

}

#----------------------------------------------------------------------

sub get_title_from_pattern_match2 {
  my(%params) = @_;
  my $show = $params{show};
  my $episode_part = $params{episode_part};
  my $content = $params{content};
  my $seek_episode = $params{seek_episode};

  while ($content =~ /($show->{episode_pattern})/g) {
    my $episode_block = $1;
    my($episode_num) = ($episode_block =~ /$show->{episode_num_pattern}/);
    my($episode_name) = ($episode_block =~ /$show->{episode_name_pattern}/);
    if ($episode_num && $episode_num == $seek_episode) {
      return clean_episode_name($episode_name);
    }
  }
}
#----------------------------------------------------------------------

sub clean_episode_name {
  my($episode_name) = @_;
  $episode_name =~ s/^\|?[\s\']*//;
  $episode_name =~ s/[\s\']*$//;
  $episode_name =~ s/\[\[.*?\|//;
  $episode_name =~ s/\[\[//;
  $episode_name =~ s/\]\]//;
  $episode_name =~ s/\&quot;//g;
  $episode_name =~ s/\?//g;
  $episode_name =~ s/\s*:\s*/ - /g;
  return $episode_name;
}

#----------------------------------------------------------------------

sub get_title_from_table {
  my(%params) = @_;
  my $show = $params{show};
  my $episode_part = $params{episode_part};
  my $content = $params{content};
  my $seek_episode = $params{seek_episode};

  my $ep_num_column = (defined $show->{ep_num_column} ? $show->{ep_num_column} : 1);
  my $name_column = $show->{name_column} || 4;

  my $te = HTML::TableExtract->new(headers => [ '#', 'Title' ],
                                   slice_columns => 0);
  $te->parse($content);

  for my $table ($te->tables) {
    for my $row ($table->rows) {
      if ($row->[$ep_num_column] && $row->[$ep_num_column] eq $seek_episode) {
        my $episode_name =  $row->[$name_column];
        if ((grep { $episode_name eq $_ } qw(Amazon N Y 0)) || $episode_name =~ /^\d+$/) {
          $episode_name =  $row->[$name_column - 1];
        }
        $episode_name =~ s/\(a.k.a .*\)//;
        if ($episode_part) {
          my @episode_name_parts = split(m|\s+/\s+|, $episode_name);
          $episode_name = $episode_name_parts[ord($episode_part) - ord('a')];
        }
        $episode_name =~ s/^\s*//;
        $episode_name =~ s/\s*$//;
        if ($show->{remove_quotes}) {
          $episode_name =~ s/^"//;
          $episode_name =~ s/"$//;
        }
        # Windows file systems don't like colons, so replace them with dash
        $episode_name =~ s/\s*:\s*/ - /g;
        $episode_name =~ s/"/'/g;
        $episode_name =~ s/\?//g;
        return $episode_name;
      }
    }
  }
}

#----------------------------------------------------------------------

sub get_titles_from_cache {
  my($show, $season) = @_;
  my $base_dir = "$ENV{HOME}/.video_rename";
  mkdir $base_dir unless -d $base_dir;

  my $show_file = "$base_dir/$show->{show_name}";
  if ($show->{url} ne 'fake source' &&
      (! -f $show_file ||
       -M $show_file > 1)) {
    $ua->agent('Showlister/0.1');
    getstore($show->{url}, $show_file);
  }

  return read_file($show_file);
}

#----------------------------------------------------------------------

sub get_show_from_filename {
  my($filename) = @_;
  my %possible_shows = map { (lower_clean($_) => $_) } keys %shows;
  for my $k (keys %shows) {
    if ($shows{$k}->{alt_title}) {
      if (ref($shows{$k}->{alt_title})) {
        for my $alt_title (@{$shows{$k}->{alt_title}}) {
          $possible_shows{lower_clean($alt_title)} = $k;
        }
      }
      else {
        $possible_shows{lower_clean($shows{$k}->{alt_title})} = $k;
      }
    }
  }

  $filename =~ s/^\d+\s*//; # for ducktales
  my @parts = split(m/(\s|_)*([-\/]|[\. _](season\s+|s?o?)\d+)(\s|_)*/i, $filename);
  for my $p (@parts) {
    $p = lower_clean($p);

    my(@matches) = grep($p eq $_, keys %possible_shows);
    if (@matches) {
      return $shows{$possible_shows{$matches[0]}};
    }
  }
  return;
}

#----------------------------------------------------------------------

sub lower_clean {
  my($str) = @_;
  return '' unless $str;

  $str = lc($str);
  $str =~ s/\./ /g;
  $str =~ s/\'//g;
  $str =~ s/[^a-z0-9]+/ /g;
  return $str;
}

#----------------------------------------------------------------------

sub get_title {
    my(%params) = @_;
    my $show = $params{show};

    my $episodes = get_episodes(show => $show);

    for my $ep_rec (@$episodes) {
        if (($show->{no_season_num} || ($params{season} && $ep_rec->{season} == $params{season})) &&
            $ep_rec->{episode} == $params{episode}) {

            my $title = $ep_rec->{title};
            if ($show->{fixup_regexp}) {
                eval '$title =~ ' . $show->{fixup_regexp};
            }
            return $title;
        }
    }
    return '';
}

#----------------------------------------------------------------------

sub get_episodes {
    my(%params) = @_;
    my $show = $params{show};
    my $episodes;
    if ($show->{imdb}) {
        return VideoName::get_episodes_from_imdb(show => $show);
    }
    elsif ($show->{wiki}) {
        return VideoName::get_episodes_from_wiki(show => $show);
    }
    else {
        my $cache_file = "$ENV{HOME}/.video_rename/$show->{show_name}.yaml";
        if (-f $cache_file) {
            return LoadFile($cache_file);
        }
        warn "Episode list not handled!\n";
        return [];
    }
}

#----------------------------------------------------------------------

sub get_episode_from_title {
    my(%params) = @_;

    my $show = $params{show};
    my $filename = $params{filename};
    $filename =~ s/.*\///;
    $filename =~ s/\.[^\.]*$//;
    $filename = lc $filename;
    $filename =~ s/_/ /g;
    $filename =~ s/^\s*//;
    $filename =~ s/\s*$//;
    $filename =~ s/\s+/ /g;
    my $show_name = lc $show->{show_name};
    $show_name =~ s/\s+/[- .]+/g;
    $filename =~ s/^$show_name(\s*-)?\s*//i;
    $filename =~ s/^\d+(x\d+)?\s*-//;
    $filename =~ s/^s\d+ ?e\d+\s*-//i;
    my $episodes = get_episodes(show => $show);
    my %episodes;
    for my $ep (@$episodes) {
        my $key = lc $ep->{title};
        $episodes{$key} = $ep;
    }
    my @matches = String::Approx::amatch($filename, keys %episodes);
    if (scalar @matches > 1) {
        print "Many matches: " . join(',', @matches) . "\n\n";
        if (exists $episodes{$filename}) {
            print "But one is triumphant!\n";
            return ($episodes{$filename}->{season},
                    $episodes{$filename}->{episode});
        }
        return;
    }
    elsif (!@matches) {
        if ($filename =~ s/:.*$//) {
            return get_episode_from_title(show => $show,
                                          filename => $filename);
        }
        print "No matches\n";
        return;
    }
    else {
        return ($episodes{$matches[0]}->{season},
                $episodes{$matches[0]}->{episode});
    }
}


#----------------------------------------------------------------------

sub search_for_missing_show {

    while (1) {
        my $search_term = $term->readline("\nEnter search term for show: ");
        my $imdb = IMDB::Film->new(crit => $search_term);
        print "Possible matches:\n";
        my @matched = @{$imdb->matched};
        for my $i (0..$#matched) {
            print "\t" . ($i + 1) . " - $matched[$i]->{title}\n";
        }
        print "\n";
        my $choice = $term->readline("Choose: ");
        if ($choice eq 'n') {
            return;
        }
        $imdb = IMDB::Film->new(crit => $matched[$choice - 1]->{id});
        my $title = $imdb->title;
        $title =~ s/\"//g;

        print "Show found: ". $title . "\n";
        print "Year: ". $imdb->year . "\n";
        print "Plot: ". $imdb->plot . "\n";
        print "Id: ". $imdb->code . "\n";

        my $correct = $term->readline("\nIs this correct? (Y/n) ");
        if ($correct =~ /^y(es)?$/i) {
            $shows{$title}->{imdb} = $imdb->code;
            $shows{$title}->{show_name} = $title;

            my $alt_title = $term->readline("\nAlternate title: ");
            if ($alt_title) {
                $shows{$title}->{alt_title} = [ split(/\s*,\s*/, $alt_title) ];
            }

            my $group = $term->readline("\nShow group: ");
            if ($group) {
                $shows{$title}->{video_type} = $group;
            }

            return $shows{$title};
        }
    }

}
