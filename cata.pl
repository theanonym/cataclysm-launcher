#!/bin/perl
use v5.20;
use utf8;
use autodie;
no warnings "experimental";

use Getopt::Long;
use FindBin;
use Cwd qw/abs_path/;
use File::Basename qw/basename dirname/;
use File::Spec::Functions qw/catfile catdir canonpath/;
use File::Slurp qw/read_file write_file/;
use File::Path qw/remove_tree make_path/;
use File::Copy qw/copy move/;
use File::Copy::Recursive qw/dircopy dirmove/;
use File::Find::Rule;
use List::Util qw/min max/;
use List::MoreUtils qw/first_index first_value any only_value /;
use Archive::Extract;   
use LWP;
use JSON;

################################################################################
#
# Глобальные переменные
#
################################################################################
our $IS_WINDOWS = $ENV{OS} =~ /win/i;
our $IS_64bit   = $ENV{PROCESSOR_ARCHITECTURE} =~ /64/;

our $LAUNCHER_PATH = $FindBin::Bin;

our $MAIN_CONFIG     = json_to_perl(read_file catfile($LAUNCHER_PATH, "launcher_config.json"));
our $FASTMOD_CONFIG  = json_to_perl(read_file catfile($LAUNCHER_PATH, "fastmod_config.json"));
die "Cannot load config files." unless $MAIN_CONFIG && $FASTMOD_CONFIG;

our $GAME_PATH = $MAIN_CONFIG->{game_path} ? $MAIN_CONFIG->{game_path} : catdir $LAUNCHER_PATH, "..";

chdir $GAME_PATH;

our $LWP = LWP::UserAgent->new;
$LWP->agent("Mozilla/5.0 (Windows NT 6.1; rv:64.0) Gecko/20100101 Firefox/64.0");
$LWP->cookie_jar({});

our %OPT;

################################################################################
#
# Код лаунчера
#
################################################################################
sub json_to_perl($) {
   my($json_string) = join "\n", @_;
   JSON->new->utf8->decode($json_string);
}

sub perl_to_json($) {
   my($array_ref) = @_;
   JSON->new->utf8->allow_nonref->pretty->encode($array_ref);
}

#------------------------------------------------------------

sub get_game_executable() {
   if($IS_WINDOWS) {
      for("cataclysm.exe", "cataclysm-tiles.exe") {
         my $file = catfile $GAME_PATH, $_;
         -f $file and return $file;
      }
   } else {
      for("cataclysm", "cataclysm-tiles") {
         my $file = catfile $GAME_PATH, $_;
         -f $file and return $file;
      }
   }
   
   die "Cannot find game executable.";
}

sub launch_game() {
   my $executable = get_game_executable;
   
   say "Launch '$executable'";
   exec $executable;
   
   exit;
}

sub get_build_version($) {
   my($path_or_url) = @_;
   return ($path_or_url =~ /(\d+)\D*$/)[0];
}

sub fetch_latest_game_url() {
   my $page_url = sprintf "http://dev.narc.ro/cataclysm/jenkins-latest/%s%s/%s/",
                          $IS_WINDOWS  ? "Windows" : "Linux",
                          $IS_64bit    ? "_x64"    : "",
                          $OPT{curses} ? "Curses"  : "Tiles";
                      
   my $res = $LWP->get($page_url);
   die unless $res->is_success;

   my @archives = $res->content =~ m~href="(cataclysmdda.*?\d+(?:\.zip|\.tar\.gz))"~gs;
   die unless @archives;
   
   return "$page_url" . (sort { $a <=> $b } @archives)[0];
}

sub check_for_update() {
   say "'$MAIN_CONFIG->{version_file}' not found! Try --update" and exit
      unless -s $MAIN_CONFIG->{version_file};

   my $current_version = read_file $MAIN_CONFIG->{version_file};
   my $latest_version  = get_build_version fetch_latest_game_url;
   my $is_latest = $current_version >= $latest_version;

   printf "Your build:   %d\nLatest build: %d (+%d)\n%s\n",
          $current_version,
          $latest_version,
          $latest_version - $current_version,
          $is_latest ? "Game is up to date!" :
                       "Try --update";
   return $is_latest;
}

sub download_file($$) {
   my($url, $path_to_save) = @_;
   
   $LWP->show_progress(1);
   my $res = $LWP->get($url, ":content_file" => $path_to_save);
   $LWP->show_progress(0);
   
   die "Download error" unless $res->is_success && -s $path_to_save;
}

sub backup_files($$) {
   my($from_path, $to_path) =  @_;
   
   die "'$from_path' not found!" unless -d $from_path;
   
   unless(-d $to_path) {
      printf "Create '%s'\n", basename $to_path;
      mkdir $to_path;
   }
   
   map { $_ = canonpath abs_path $_ } ($from_path, $to_path);

   for my $world_name ( map { basename $_ } grep { -d } glob catdir $from_path, "*") {
   
      my $old_world_path = catdir $to_path, $world_name;
      if(-d $old_world_path) {
         printf "Delete '%s'\n",  catdir(basename($to_path), $world_name);
         remove_tree $old_world_path;
      }
      
      printf "Copy '%s' -> '%s'\n", catdir(basename($from_path), $world_name),
                                    catdir(basename($to_path), $world_name);
      dircopy catdir($from_path, $world_name), catdir($to_path, $world_name);
   }
}

#------------------------------------------------------------

sub update_game() {
   my $url = fetch_latest_game_url;
   my $archive_name  = basename $url;
   my $unpacked_folder = ".";
   
   # Download 
   say "Download '$archive_name'";
   $OPT{nodownload} && -s $archive_name ?  say "...skip download (--nodownload option)" :
                                           download_file $url, $archive_name; 

   # Save important files
   my $data_folder = "data";
   my $tmp_folder = "important_files.tmp";
   
   if(-d $data_folder || -d "gfx") {
      say "Create '$tmp_folder'";
      make_path catdir $tmp_folder, $data_folder ;
      make_path catdir $tmp_folder, "gfx";

      for my $important_file(catfile($data_folder, "fontdata.json"),
                             catfile($data_folder, "font"),
                             catfile("gfx", "MSX++DeadPeopleEdition"),
      ) {
         my $new_path = catdir $tmp_folder, $important_file;
         
         if(-d $important_file) {
            say "Copy '$important_file' -> '$new_path'";
            dircopy $important_file, $new_path or die $!;
         } elsif(-f $important_file) {
            say "Copy '$important_file' -> '$new_path'";
            copy $important_file, $new_path or die $!;
         } else {
            say "'$important_file' not found";
         }
      }
   }

   # Extract 
   if(-d $data_folder) {
      say "Delete '$data_folder'";
      remove_tree $data_folder;
   }
   
   if(-d $FASTMOD_CONFIG->{fastmod_data_backup}) {
      say "Delete '$FASTMOD_CONFIG->{fastmod_data_backup}'";
      remove_tree $FASTMOD_CONFIG;
   }
   
   say "Extract '$archive_name' -> '$unpacked_folder'";
   my $archive = Archive::Extract->new(archive => $archive_name);
   $archive->extract(to => $unpacked_folder);
   die $archive->error if $archive->error;
   
   if($archive->is_tgz) {
      # Unpack tar
      printf "Move '%s' -> '%s'\n", basename($archive->extract_path), $unpacked_folder;
      dirmove $archive->extract_path, "." or die $!;
      # printf "Delete '%s'", basename($archive->extract_path);
      # rmdir $archive->extract_path;
   }
   
   say "Create '$MAIN_CONFIG->{version_file}'";
   write_file $MAIN_CONFIG->{version_file}, get_build_version $url;
   
   # Restore important files
   if(-d $tmp_folder) {
      printf "Copy '%s' -> '%s'\n", catdir($tmp_folder, $data_folder), ".";
      dircopy $tmp_folder, ".";
   
      say "Delete '$tmp_folder'";
      $OPT{keep} ? say "...skip deletion (--keep option)" :
                   remove_tree $tmp_folder; 
   }
   
   # Clean up
   say "Delete '$archive_name'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                unlink $archive_name; 
}

sub update_2ch_tileset() {
   my $url = $MAIN_CONFIG->{"2chtileset_url"};
   my $archive_name  = "DeadPeopleTileset.zip";
   my $unpacked_folder = "$archive_name.unpacked";
   
   # Download 
   say "Download '$archive_name'";
   ($OPT{nodownload} && -s $archive_name) ? say "...skip download (--nodownload option)" :
                                            download_file $url, $archive_name;

   say "Extract '$archive_name' -> '$unpacked_folder'";
   my $archive = Archive::Extract->new(archive => $archive_name);
   $archive->extract(to => $unpacked_folder);
   die $archive->error if $archive->error;

   # Update
   my $new_tileset_dir = catdir($unpacked_folder, only_value { basename($_) eq "MSX++DeadPeopleEdition" } @{$archive->files});
   my $new_mod_dir     = catdir($unpacked_folder, only_value { basename($_) eq "mods" } @{$archive->files});
   my $tilesets_path   = catdir ".", "gfx", basename($new_tileset_dir);
   my $mods_path       = catdir ".", "data", "mods";

   printf "Move '...%s' -> '%s'\n", basename($new_tileset_dir), $tilesets_path;
   dirmove $new_tileset_dir, $tilesets_path or die $!;
   printf "Move '...%s' -> '%s'\n", basename($new_mod_dir), $mods_path;
   dirmove $new_mod_dir, $mods_path or die $!;
   
   # Clean up
   say "Delete '$unpacked_folder'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                remove_tree $unpacked_folder; 

   say "Delete '$archive_name'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                unlink $archive_name; 
}

sub update_2ch_soundpack() {
   my $url = $MAIN_CONFIG->{"2chsoundpack_url"};
   my $archive_name  = "2chsound.zip";
   my $unpacked_folder = catdir ".", "sound";
   
   # Download 
   say "Download '$archive_name'";
   ($OPT{nodownload} && -s $archive_name) ? say "...skip download (--nodownload option)" :
                                            download_file $url, $archive_name;

   # Extract
   unless(-d $unpacked_folder) {
      say "Create '$unpacked_folder'";
      make_path $unpacked_folder;
   }             
   
   say "Extract '$archive_name' -> '$unpacked_folder'";
   my $archive = Archive::Extract->new(archive => $archive_name);
   $archive->extract(to => $unpacked_folder);
   die $archive->error if $archive->error;
   
   # Clean up
   say "Delete '$archive_name'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                unlink $archive_name; 
}

sub update_2ch_musicpack() {
   my $url = $MAIN_CONFIG->{"2chmusic_url"};
   my $archive_name  = "2chmusic.zip";
   my $unpacked_folder = catdir ".", "sound", "2ch sounpack";
   
   unless(-d $unpacked_folder) {
      say "2ch Sound Pack must be installed first! Try --2chsound";
      return;
   }
   
   # Download 
   my $res = $LWP->get($url);
   my($new_url) = $res->content =~ m~href="/(uc\?export\=download&amp;confirm\=.*?&amp;id\=.*?)">D~gms;
   die unless $new_url;
   $new_url = "https://docs.google.com/$new_url";
   $new_url =~ s/&amp;/&/g;

   say "Download '$archive_name'";
   ($OPT{nodownload} && -s $archive_name) ? say "...skip download (--nodownload option)" :
                                            download_file $new_url, $archive_name;

   # Extract
   say "Extract '$archive_name' -> '$unpacked_folder'";
   my $archive = Archive::Extract->new(archive => $archive_name);
   $archive->extract(to => $unpacked_folder);
   die $archive->error if $archive->error;
   
   # Clean up
   say "Delete '$archive_name'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                unlink $archive_name; 
}

sub install_mod_from_github {
   my($github_link) = @_;

   unless(-d "mods") {
      say "Create 'mods'";
      mkdir "mods";
   }
   
   # Download 
   $github_link =~ s~/\s*$~~s;
   my $url = "$github_link/archive/master.zip";
   my ($mod_name) = $github_link =~ m~/([^/]*)$~;
   my $archive_name = "$mod_name.zip";
   
   say "Download '$archive_name'";
   ($OPT{nodownload} && -s $archive_name) ? say "...skip download (--nodownload option)" :
                                            download_file $url, $archive_name;

   # Extract
   my $mod_path = catdir "mods", "$mod_name-master";
   if(-d $mod_path) {
      say "Delete '$mod_path'";
      remove_tree $mod_path;
   }
   
   say "Extract '$archive_name' -> 'mods'";
   my $archive = Archive::Extract->new(archive => $archive_name);
   $archive->extract(to => "mods");
   die $archive->error if $archive->error;
   
   # Clean up
   say "Delete '$archive_name'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                unlink $archive_name; 
}

################################################################################
#
# Код мода
#
################################################################################
sub report(@) {
   my(@strings) = map { "$_\n" } @_;

   state $log;
   open $log, ">", catfile($LAUNCHER_PATH, $FASTMOD_CONFIG->{log_file}) unless defined $log;
   #print @strings;
   print $log @strings;
}

sub compute_new_time($$) {
   my($original_time, $requirement_type) = @_;
   #$original_time = max(60000, $original_time);
   int max 0, $original_time * $FASTMOD_CONFIG->{"parts_${requirement_type}_time"};
}

sub compute_time_from_difficulty($$) {
   my($difficulty, $requirement_type) = @_;
   ($difficulty + 1) * 30000;
}

sub has_standard_difficulty($) {
   my($node) = @_;
   exists $node->{difficulty};
}

sub has_difficulty_in_requirements($$) {
   my($node, $requirement_type) = @_;
   exists $node->{requirements}->{$requirement_type}->{skills}
          && any { "mechanics" } $node->{requirements}->{$requirement_type}->{skills};
}

sub has_time_in_requirements($$) {
   my($node, $requirement_type) = @_;
   exists $node->{requirements}->{$requirement_type}->{time};
}

sub has_parent($) {
   my($node) = @_;
   exists $node->{"copy-from"};
}

sub get_parent($$) {
   my($json, $node) = @_;
   die perl_to_json $node unless has_parent $node;
   
   my $copy_from = $node->{"copy-from"};
   first_value { $_->{id} eq $copy_from || $_->{abstract} eq $copy_from } @$json
}

sub get_id($) {
   my($node) = @_;
   $node->{id} ? $node->{id} : $node->{result} ? $node->{result} : $node->{abstract};
}

sub get_standard_difficulty($) {
   my($node) = @_;
   die perl_to_json $node unless has_standard_difficulty $node;
   
   $node->{difficulty};
}

sub get_difficulty_from_requirements($$) {
   my($node, $requirement_type) = @_;
   die perl_to_json $node unless has_difficulty_in_requirements $node, $requirement_type;
   
   $node->{requirements}->{$requirement_type}->{skills}->[
      first_index { "mechanics" } $node->{requirements}->{$requirement_type}->{skills}
      + 1
   ]->[1];
}

sub get_time_from_requirements($$) {
   my($node, $requirement_type) = @_;
   die perl_to_json $node unless has_time_in_requirements $node, $requirement_type;
   
   $node->{requirements}->{$requirement_type}->{time};
}

sub set_time_to_requirements($$$) {
   my($node, $requirement_type, $time) = @_;
   
   $node->{requirements}->{$requirement_type}->{time} = int $time;
}

sub set_difficulty_to_requirements($$$) {
   my($node, $requirement_type, $difficulty) = @_;
   
   push @{ $node->{requirements}->{$requirement_type}->{skills} }, [ "mechanics", int $difficulty ];
}

sub fast_mod_make_backup {
   report "Backup original files to '$FASTMOD_CONFIG->{data_backup}'...";
   dircopy catdir(".", "data", "json"), catdir(".", $FASTMOD_CONFIG->{data_backup}, "json");
   dircopy catdir(".", "data", "mods"), catdir(".", $FASTMOD_CONFIG->{data_backup}, "mods");
   report "Done";
}

sub fast_mod_restore {
   unless(-d $FASTMOD_CONFIG->{data_backup}) {
      say "'$FASTMOD_CONFIG->{data_backup}' not found!";
      return;
   }

   say "Restoring original files...";
   dircopy catdir(".", $FASTMOD_CONFIG->{data_backup}, "json"), catdir(".", "data", "json");
   dircopy catdir(".", $FASTMOD_CONFIG->{data_backup}, "mods"), catdir(".", "data", "mods");
   
   say "Delete '$FASTMOD_CONFIG->{data_backup}'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                remove_tree "$FASTMOD_CONFIG->{data_backup}";
   
}

sub fast_mod_apply {
   if(-d $FASTMOD_CONFIG->{data_backup}) {
      say "Game files already modified. Try --restore old files or --update to new build.";
      return;
   } else {
      fast_mod_make_backup;
   }

   my %count = (checked => 0, modified => 0, parts => 0, books => 0, mutations => 0);

   for my $file_path (
      File::Find::Rule->file->name("*.json")->in(
         catdir(".", "data", "json", "vehicleparts"),
         catdir(".", "data", "json", "items", "book"),
         catdir(".", "data", "json", "recipes"),
         catdir(".", "data", "mods"),
      ),
      catfile(".", "data", "json", "mutations.json"),
   ) {
      $count{checked}++;
      
      my $text = read_file $file_path;
      my $file_modified = 0;
      
      my $json = json_to_perl($text);
      next if ref $json ne "ARRAY";
      
      for my $node (@$json) {
         next if ref $node ne "HASH";
         next unless exists $node->{type};
         
         my $id = get_id($node);
         my $node_modified = 0;
         
         given($node->{type}) {
            when("vehicle_part") {
               for my $requirement_type ("install", "repair", "removal") {
                  my $original_difficulty;
                  my $original_time;
                  
                  if(has_difficulty_in_requirements $node, $requirement_type) {
                     $original_difficulty = get_difficulty_from_requirements $node, $requirement_type;
                  } elsif (has_standard_difficulty $node) {
                     $original_difficulty = get_standard_difficulty $node;
                  } elsif(has_parent $node) {
                     my $parent_node = get_parent($json, $node);
                     if(has_standard_difficulty $parent_node) {
                        $original_difficulty = get_standard_difficulty $parent_node;
                     } elsif(has_difficulty_in_requirements $parent_node, $requirement_type) {
                        $original_difficulty = get_difficulty_from_requirements $parent_node,
                                                                                $requirement_type;
                     } else {
                        report "Part '$id' has no difficulty";
                     }
                  }
                  
                  die if defined $original_difficulty && length $original_difficulty == 0;
                  
                  if(has_time_in_requirements $node, $requirement_type) {
                     $original_time = get_time_from_requirements $node, $requirement_type;
                     if(defined $original_difficulty) {
                        $original_time = min($original_time,
                                             compute_time_from_difficulty $original_difficulty,
                                                                          $requirement_type);
                     }
                  } elsif(defined $original_difficulty) {
                     $original_time = compute_time_from_difficulty $original_difficulty,
                                                                   $requirement_type;
                  }
                  
                  if(defined $original_time) {
                     set_time_to_requirements $node,
                                              $requirement_type,
                                              compute_new_time $original_time, $requirement_type;
                                              
                     if(defined $original_difficulty && !has_difficulty_in_requirements $node, $requirement_type) {
                        set_difficulty_to_requirements $node,
                                                       $requirement_type,
                                                       $original_difficulty;
                     }

                     report sprintf "Part '%s'%s (difficulty: %d): change $requirement_type time %d -> %d",
                        $id,
                        has_parent($node)?" (parent: '" . get_id(get_parent($json, $node)) . "')":"",
                        $original_difficulty,
                        $original_time,
                        compute_new_time $original_time, $requirement_type;
                        
                     $file_modified = 1;
                     $node_modified = 1;
                     $count{parts}++;
                  } elsif(defined $original_difficulty && !exists $node->{abstract}) {
                     report "Can't determine $requirement_type time for '$id'";
                  }
               }
            }
            when("BOOK") {
               if(exists $node->{time}) {
                  my $old_time = $node->{time};
                  my $new_time = int($old_time * $FASTMOD_CONFIG->{books_time});
                  $new_time = 1 if $new_time < 1 && $old_time >= 1;
                  $node->{time} = $new_time;
                  
                  report "Book '$node->{id}': change reading time $old_time -> $new_time";
                  
                  $file_modified = 1;
                  $node_modified = 1;
                  $count{books}++;
               }
            }
            when("recipe") {
               if(exists $node->{time}) {
                  my $id = get_id($node);
                  my $old_time = $node->{time};
                  my $new_time = int($old_time * $FASTMOD_CONFIG->{books_time});
                  $new_time = 1 if $new_time < 1 && $old_time >= 1;
                  $node->{time} = $new_time;
                  
                  report "Recipe '$id': change craft time $old_time -> $new_time";
                  
                  $file_modified = 1;
                  $node_modified = 1;
                  $count{recipes}++;
               } else {
                  report "Recipe '$id' has no time";
               }
            }
            when("mutation") {
               if(any { $_ eq $node->{id} } @{ $FASTMOD_CONFIG->{sleep_mutations} }) {
                  $node->{fatigue_regen_modifier} = $FASTMOD_CONFIG->{sleep_acceliration};
                  
                  report "Mutation '$node->{id}': faster sleep effect added";
                  
                  $file_modified = 1;
                  $node_modified = 1;
                  $count{mutations}++;
               }
            }
         }
         
         if($node_modified) {
            #$node->{MODIFIED} = $JSON::true;
         }
      }
      
      for my $node (grep { ref $_ eq "HASH" && $_->{type} eq "vehicle_part" } @$json) {
         for my $requirement_type ("install", "repair", "removal") {
            if(exists $node->{requirements}->{$requirement_type} && %{$node->{requirements}->{$requirement_type}} == 0) {
               delete $node->{requirements}->{$requirement_type};
            }
         }
      }
      
      if($file_modified) {
         write_file $file_path, perl_to_json $json;
         
         $count{modified}++;
      }
   }

   report "\nFiles checked: $count{checked}",
          "Files edited: $count{modified}",
          "Parts: $count{parts}",
          "Books: $count{books}",
          "Recipes: $count{recipes}",
          "Mutations: $count{mutations}";
          
   say "Done. Read '$FASTMOD_CONFIG->{log_file}' for details.";
}

################################################################################
#
# Начало программы
#
################################################################################

GetOptions \%OPT,
   # Actions
   "launch", "check", "update", "save", "load",
   "2chtiles", "2chsound", "2chmusic",
   "fastmod", "restore",
   "mod=s@",
   # Options
   "nodownload", "keep", "curses",
   "help|?"    => sub {
   print <<USAGE;
Game:
   --launch      Launch game executable
   --check       Check for aviable update
   --update      Install/Update game to latest version
                 Warning: non-standard mods in data/mods will be deleted,
                 use mods/ folder for them.
   --curses      Dowload Curses version of game
               
   --save        Backup saves
   --load        Restore saves
   
Resources:
   --2chtileset  Install/Update Dead People tileset
   --2chsound    Install/Update 2ch Sounpack
   --2chmusic    Install/Update 2ch Music Pack

Mods:
   --mod [link]  Install/Update a mod from gihub

Options:
   --keep        Don't delete temporary files
   --nodownload  Don't download file if it already exists
   
"Fast Cata" mod:
   --fastmod     Backup original files and apply mod
   --restore     Restore original files
USAGE
   exit;
};

#------------------------------------------------------------

unless(%OPT) {
   say "Do nothing. Try --help";
   exit;
}

if($OPT{check})      { check_for_update }
if($OPT{update})     { update_game }
if($OPT{"2chtiles"}) { update_2ch_tileset }
if($OPT{"2chsound"}) { update_2ch_soundpack }  
if($OPT{"2chmusic"}) { update_2ch_musicpack } 
if($OPT{restore})    { fast_mod_restore }      
if($OPT{fastmod})    { fast_mod_apply }        
if($OPT{mod})        { install_mod_from_github $_ for @{$OPT{mod}}; }
if($OPT{save})       { say "Backup saves...";  backup_files "save", "save.bk"; }
if($OPT{load})       { say "Restore saves..."; backup_files "save.bk", "save"; }
if($OPT{launch})     { launch_game }
