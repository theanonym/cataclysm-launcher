#!/bin/perl
use v5.20;
use utf8;
use autodie;
no warnings "experimental";

use Getopt::Long;
use POSIX qw/uname/;
use Cwd qw/abs_path/;
use File::Basename qw/basename/;
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
# Настройки мода Fast Cata
#
################################################################################
our %MOD_SETTINGS = (
   # Коэффициенты времени выполнения
   # 1 = 100%
   parts_install_time => 0.2, # Время установки деталей 0.2 = 20%
   parts_repair_time  => 0.2, # Ремонта
   parts_removal_time => 0.2, # Удаления
   
   craft_time         => 0.2, # Время крафта
   books_time         => 0.2, # Чтения
   
   # К указанной мутации добавляется эффект ускоренного сна
   sleep_acceliration => 1.0,            # 1.0 = энергия восстанавливается на 100% быстрее
   sleep_mutation_id  => "HEAVYSLEEPER", # Крепкий сон
);

################################################################################
#
# Глобальные переменные
#
################################################################################
our $VERSION_FILE = "_VERSION.txt";
our $DATA_BACKUP  = "data.bk";
our $MOD_LOG      = "cata.pl.log";

our $LWP = LWP::UserAgent->new;
$LWP->agent("Mozilla/5.0 (Windows NT 6.1; rv:64.0) Gecko/20100101 Firefox/64.0");
$LWP->cookie_jar({});

our %OPT;

our %MODS = (
   "pc_rebalance" => { name => "PK's Rebalancing", url => "https://github.com/Dissociativity/PKs_Rebalancing/archive/master.zip" },
   "cataclysm++"  => { name => "Cataclysm++", url => "https://github.com/Noctifer-de-Mortem/nocts_cata_mod/archive/master.zip" },
   "arcana"       => { name => "Arcana", url => "https://github.com/chaosvolt/cdda-arcana-mod/archive/master.zip" },
);

################################################################################
#
# Код лаунчера
#
################################################################################
sub get_build_version($) {
   my($path_or_url) = @_;
   return ($path_or_url =~ /(\d+)\D*$/)[0];
}

sub fetch_latest_game_url() {
   my($sysname, $arch) = (POSIX::uname)[0, 4];
   my $page_url = sprintf "http://dev.narc.ro/cataclysm/jenkins-latest/%s%s/%s/",
                          $sysname =~ /win/i ? "Windows" : "Linux",
                          $arch =~ /64/  ? "_x64" : "",
                          $OPT{curses} ? "Curses" : "Tiles";
                      
   my $res = $LWP->get($page_url);
   die unless $res->is_success;

   my @archives = $res->content =~ m~href="(cataclysmdda.*?\d+(?:\.zip|\.tar\.gz))"~gs;
   die unless @archives;
   
   return "$page_url" . (sort { $a <=> $b } @archives)[0];
}

sub check_for_update() {
   say "'$VERSION_FILE' not found! Try --update" and exit
      unless -s $VERSION_FILE;

   my $current_version = read_file $VERSION_FILE;
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
   
   say "Create '$VERSION_FILE'";
   write_file $VERSION_FILE, get_build_version $url;
   
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
   my $url = "https://github.com/SomeDeadGuy/Cata-MSX-DeadPeopleTileset/archive/master.zip";
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
   my $url = "https://docs.google.com/uc?id=1ZQRqnPL7d9pjfH1GdZWft8ZmZFuq6XpD&export=download";
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
   my $url = "https://docs.google.com/uc?id=1n7UWnZzQC270Q7bpHdczIK0Yp-LKa16i&export=download";
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

sub update_mod {
   my($mod_name) = @_;
   my $mod = $MODS{$mod_name} or say "Unknown mod '$mod_name'!" and return;

   unless(-d "mods") {
      say "Create 'mods'";
      mkdir "mods";
   }
   
   # Download 
   my($ext) = $mod->{url} =~ /\.([^\.]*)$/;
   my $archive_name = "$mod->{name}.$ext";
   my $mod_path = catdir "mods", $mod->{name};

   say "Download '$archive_name'";
   ($OPT{nodownload} && -s $archive_name) ? say "...skip download (--nodownload option)" :
                                            download_file $mod->{url}, $archive_name;

   # Extract
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
   open $log, ">", $MOD_LOG unless defined $log;
   #print @strings;
   print $log @strings;
}

sub json_to_perl($) {
   my($json_string) = @_;
   JSON->new->utf8->decode($json_string);
}

sub perl_to_json($) {
   my($array_ref) = @_;
   JSON->new->utf8->allow_nonref->pretty->encode($array_ref);
}

sub compute_new_time($$) {
   my($original_time, $requirement_type) = @_;
   #$original_time = max(60000, $original_time);
   int max 0, $original_time * $MOD_SETTINGS{"parts_${requirement_type}_time"};
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
   report "Backup original files to '$DATA_BACKUP'...";
   dircopy catdir(".", "data", "json"), catdir(".", $DATA_BACKUP, "json");
   dircopy catdir(".", "data", "mods"), catdir(".", $DATA_BACKUP, "mods");
   report "Done";
}

sub fast_mod_restore {
   unless(-d $DATA_BACKUP) {
      say "'$DATA_BACKUP' not found!";
      return;
   }

   say "Restoring original files...";
   dircopy catdir(".", $DATA_BACKUP, "json"), catdir(".", "data", "json");
   dircopy catdir(".", $DATA_BACKUP, "mods"), catdir(".", "data", "mods");
   
   say "Delete 'data.bk'";
   $OPT{keep} ? say "...skip deletion (--keep option)" :
                remove_tree "data.bk";
   
}

sub fast_mod_apply {
   if(-d $DATA_BACKUP) {
      say "Game files already modified. Try --restore first";
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
                  my $new_time = int($old_time * $MOD_SETTINGS{books_time});
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
                  my $new_time = int($old_time * $MOD_SETTINGS{books_time});
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
               if($node->{id} eq $MOD_SETTINGS{sleep_mutation_id}) {
                  $node->{fatigue_regen_modifier} = $MOD_SETTINGS{sleep_acceliration};
                  
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
         say "Edit file '$file_path'";
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
}

################################################################################
#
# Начало программы
#
################################################################################

GetOptions \%OPT,
   # Actions
   "check", "update", "save", "load",
   "2chtiles", "2chsound", "2chmusic",
   "fastmod", "restore",
   "mod=s@",
   # Options
   "nodownload", "keep", "curses",
   "help|?"    => sub {
   print <<USAGE;
Game:
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
   --mod %       Install/Update a mod
                 Supported mods:
                    pc_rebalance
                    cataclysm++
                    arcana

Options:
   --keep        Don't delete temporal files
   --nodownload  Don't download if file with same name already present
   
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

check_for_update      if $OPT{check};
update_game           if $OPT{update};
update_2ch_tileset    if $OPT{"2chtiles"};
update_2ch_soundpack  if $OPT{"2chsound"};
update_2ch_musicpack  if $OPT{"2chmusic"};
fast_mod_restore      if $OPT{restore};
fast_mod_apply        if $OPT{fastmod};
if($OPT{mod})  { update_mod $_ and say "" for @{$OPT{mod}}; }
if($OPT{save}) { say "Backup saves...";  backup_files "save", "save.bk"; }
if($OPT{load}) { say "Restore saves..."; backup_files "save.bk", "save"; }
