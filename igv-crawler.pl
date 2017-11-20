#!/usr/bin/env perl

#####################################################################################
#
# The MIT License (MIT)
#
# Copyright (c) 2015-2017 Jules Kerssemakers / Deutsches Krebsforschungszentrum Heidelberg (DKFZ)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
# OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#####################################################################################

#
# This script recursively scans the specified folder for
# files with extensions that IGV can handle.
# These files are then linked in a separate links folder and a .html
# page is created with clickable links using IGV's HTML link control feature:
# http://software.broadinstitute.org/software/igv/ControlIGV
#

use strict;
use warnings;
use 5.010;

use Date::Format;
use File::stat;
use File::Find::Rule;
use File::Path;
use File::Spec::Functions;
use Getopt::Long;
use HTML::Template;
use Config::Simple;


#####################################################################################
# SITE CONFIG
#
my $siteconfig_file = 'igvcrawler-siteconfig.ini';
my %siteconfig = ();
die "ABORTING: could not load site-specific configuration file '$siteconfig_file'" if not -e $siteconfig_file;
Config::Simple->import_from($siteconfig_file, \%siteconfig);
# Sanity checks: all expected values should be defined

sub assert_key_exists($) {
  my ($key) = @_;
  die "ERROR: '$key' not defined in $siteconfig_file" unless exists $siteconfig{$key};
}

assert_key_exists('host_base_dir');
assert_key_exists('www_base_url');
assert_key_exists('link_dir');
assert_key_exists('page_name');
assert_key_exists('log_dir');
assert_key_exists('contact_email');

die "ERROR: specified 'host_base_dir' does not exist: $siteconfig{'host_base_dir'}" unless -d $siteconfig{'host_base_dir'};


#####################################################################################
# COMMAND LINE PARAMETERS
#
my $project_name = 'demo';        # defaults to demo-settings, to not-break prod when someone forgets to specify
my @scan_dirs;                    # list of directories that will be scanned
my @prune_dirs;                   # list of sub-directories inside @scan_dirs that will not be descended into. Can be shell globs, but not over directories. i.e. '*foo' works, 'foo/subsegment*' doesn't
my @prune_files;                  # list of globs of filenames to ignore
my $grouping_regex;               # every file-path is run through this regex to group it with related paths (pattern to group by MUST be first capture group)
my $display_mode = "nameonly";    # what to show in the HTML-file; defaults to historical behaviour: show filename without parent dir-path
my $display_regex;                # parsed version of $display_mode, in case it is a regex
my $report_mode = "counts";       # what to report? "full" > print complete lists of paths, "counts" > only print number of files/paths
my $follow_symlinks = 0;          # whether to follow symlinks (use of this option breaks some logging, due to limitations on the 'preprocess' funtion in File::Find http://perldoc.perl.org/File/Find.html)
#####################################################################################
# REPORTING VARIABLES
# We keep some counters/lists to see what kinds of trouble we run in to.
#
my $log_total_files_scanned = 0;  # total number of files seen by the find-filter (excludes unreadable directories)
my $log_deepest_scan_depth =0;
my $log_shallowest_find_depth =999;
my $log_deepest_find_depth =0;
my $log_ignored_files =0;
my $log_last_modification_time=0; # epoch timestamp of most recently changed file in the index.
my $log_total_files_displayed =0; # number of files that are displayed
my $log_total_groups_displayed =0;# number of distinct groups all the files belong to
my @log_undisplayable_paths;      # paths that didn't match the displaymode=regex parsing; what should we improve in the display-regex?
my @log_symlink_clashes;          # log if we encounter files that map to the same path, so that we are aware we are overriden/ignoring a result
my @log_ungroupable_paths;        # paths that we couldn't group, because the grouping regex didn't apply
my @log_files_without_indices;    # files we had to filter out due to missing indices
my @log_unreadable_paths;         # paths that File::find couldn't enter due to permission problems
my %log_unreadable_summary;       # Hash that has the final subdir of all unreadable paths, and their occurance count. Allows identification of recurring permission problems, e.g. tool-generated "screenshots/"
#####################################################################################

# THE var: global list to keep track of all the bam+bai files we have found
# format:
# {
#   'groupId1' => [ '/some/file/path.bam', 'some/file/path.bai', ...],
#   'groupId2' => [ '/other/file/path.bam', 'some/other/path.bai', ...],
# }
my %bambai_file_index = ();

# trap "can't cd into ..." warnings generated by File::finddepth
# N.B.: MUST be set before main() is called, otherwise it won't apply by the time it is needed.
local $SIG{__WARN__} = sub {
  my $message = shift;

  # intercept, for logging, all "can't cd to /some/path" messages generated by File::find
  #
  # Note: Regex is complicated because File::Find does preprocessing when following symlinks,
  #  this changes the warning-output... (Why Perl, WHY!?!)
  #  with follow-links:    Can't cd to /some/path/subdir: Permission denied\n at ....
  #  without follow-links: Can't cd to (/some/path) subdir: Permission denied\n at ....
  # this regex handles both cases, yielding identical capture-group output in both
  if ($message =~ /^Can't cd to \(?(.+\/)(?:\) )?([^\/]+): Permission denied/) {
    my ($pwd, $subdir) = ($1, $2);
    my $unreadable_file = "$pwd$subdir";
    push @log_unreadable_paths, $unreadable_file;

    # make an overview of which sub-dirs are unreadable how often
    # this could suggest a future sub-dir to always skip.
    if (not defined $log_unreadable_summary{$subdir}) {
      $log_unreadable_summary{$subdir} = 0;
    }
    $log_unreadable_summary{$subdir} += 1;

  # all other warnings: output fully to STDOUT
  } else {
    print 'WARN: ' . $message;
  }
};



# Actually do work :-)
main();



#####################################################################################
# FUNCTION DEFINITIONS
#


# Parses and sanity-checks the command-line parameters.
# does "die()" when anything smells weird
sub parseArgs () {
  GetOptions ('project=s'   => \$project_name,   # will be used as "the $project_name project", as well as (lowercased) subdir name
              'scandir=s'   => \@scan_dirs,      # where to look for IGV-relevant files
              'prunedir=s'  => \@prune_dirs,     # names/globs of sub-directories to skip and not descend into.
              'skipfile=s'  => \@prune_files,    # names/globs of individual files to skip.
              'groupregex=s'=> \$grouping_regex, # the regex used to group different filepaths together under a single heading in the result page.
              'display=s'   => \$display_mode,   # either the keyword "nameonly" or "fullpath", or a "regex=YOUR_REGEX" whose capture-groups will be listed.
              'report=s'    => \$report_mode,    # what to report at end-of-execution: "counts" or "full"
              'followlinks' => \$follow_symlinks # flag, follow symlinks or not?
             )
  or die("Error parsing command line arguments");

  # sanity check: project name?
  die 'No project name specified, aborting!' if ($project_name eq '');

  # sanity check: grouping regex
  die "Didn't specifify groupregex, cannot extract grouping label from file paths, aborting!" if ($grouping_regex eq "");
  die "groupregex should contain at least one capture group" if (index($grouping_regex, '(') == -1);
  # fail-fast: see if it compiles (otherwise it will only fail after we've crawled the disk -> time wasting)
  "" =~ /$grouping_regex/x;

  # sanity check: display mode
  if ($display_mode =~ /^regex=(.*)$/s) {
    $display_mode = 'regex';
    $display_regex = $1;
    if (index($display_regex, '(') == -1) {   # yes, a crafty user could fool this with (?:), but then you're intentionally messing it up
      die "display-mode regex must contain at least one capture group to display";
    }
    eval {
      $display_regex = qr/$display_regex/x; # precompile regex
    } or do {
      die "error encountered while parsing display-mode regex:\n$@";
    };
  } elsif ($display_mode ne 'nameonly' and
           $display_mode ne 'fullpath') {
    die "display mode not recognised, use either \"nameonly\", \"fullpath\" or \"regex=SOMEREGEX\"";
  }

  # sanity check: report_mode
  die "invalid report mode specified: $report_mode, use either 'counts' or 'full'" unless ( $report_mode eq "counts" or $report_mode eq "full");

  # canonicalize + sanity check @scandirs
  #
  # scandirs may be entered by either:
  # 1) repeated command line args:          "--scandir /dir/a --scandir /dir/b"
  #    --> multiple entries in @scan_dirs
  # 2) single command line arg with commas: "--scandir /dir/a,/dir/b"
  #    --> split all strings
  @scan_dirs = split(',', join(',', @scan_dirs));
  die 'Specified no directories to scan, aborting!' if ((scalar @scan_dirs) == 0);

  @prune_dirs  = split(',', join(',', @prune_dirs));
  @prune_files = split(',', join(',', @prune_files));

  my $project_name_lower = lc $project_name;
  my $output_file_path   = catfile( $siteconfig{'host_base_dir'},     $project_name_lower,      $siteconfig{'page_name'});
  my $link_dir_path      = catdir ( $siteconfig{'host_base_dir'},     $project_name_lower,      $siteconfig{'link_dir'});
  my $link_dir_url       =          $siteconfig{'www_base_url'} ."/". $project_name_lower ."/". $siteconfig{'link_dir'}; # trailing slash is added in __DATA__ template

  return ($link_dir_path, $link_dir_url, $output_file_path)
}


sub main {
  my ($link_dir_path, $link_dir_url, $output_file_path) = parseArgs();

  print "\nScanning $project_name for IGV-relevant files in:\n";
  print "  $_\n" for @scan_dirs;

  my $rule = (
    File::Find::Rule->new
      # for all files, some bookkeeping
      ->exec( sub ($$$) {
        my ($shortname, $path, $fullname) = @_;

        # count how many files we scan
        $log_total_files_scanned += 1;

        # log how far down the rabbit-hole we descend
        # (to see if setting maxdepth may help)
        my $depth = $fullname =~ tr/\//\//;
        if ($depth > $log_deepest_scan_depth) {
          $log_deepest_scan_depth = $depth;
        }

        # don't discard anything
        return 1;
      } )

      # excludes: directories and files to skip
      ->not(
        File::Find::Rule->or(
          # skip and don't descend into .hidden directories, nor user-specified folders
          File::Find::Rule->new
          ->directory
          ->or(
            File::Find::Rule->name( qr/^\..+/ ),             # skip .hidden directories (writing it as '.*' doesn't seem to work, that excludes everything?!)
            # TODO #2 PORTABILITY: un-hardcode roddy dir
            File::Find::Rule->name( 'roddyExecutionStore' ), # skip roddy working directories
            File::Find::Rule->name( @prune_dirs )            # skip user-defined directories
          )
          # TODO #11: log count of pruned dirs
          ->prune
          ->discard
        ,
          # also skip individual files specified by the user
          File::Find::Rule->new
          ->file
          ->name(@prune_files)
          ->exec(sub ($$$) { $log_ignored_files += 1; return 1; })
          ->discard
        )
      )

      # include files with IGV extensions (if they're not empty placeholders)
      ->file
      ->name(
        '*.bai',
        '*.bam',
        '*.attr.txt', # Annotation files
        '*.bed',
        '*.bedGraph', '*.bedgraph',
        '*.bigBed', '*.bigbed', '*.bb',
        '*.bigWig', '*.bigwig', '*.bw',
        '*.birdseye_canary_calls',
        '*.broadPeak', '*.broadpeak',
        '*.narrowPeak', '*.narrowpeak',
        '*.cbs',
        '*.cn',
        '*.gct',
        '*.gff', '*.gff3',
        '*.gtf',
        '*.gistic',
        '*.loh',
        '*.maf',
        '*.mut',
        '*.psl',
        '*.res',
        '*.seg',
        '*.snp',
        '*.tdf', '*.igv',
        '*.tbi', '*.idx.gz', '*.idx', # indexes
        '*.wig'
      )
      ->not_empty
  );

  # Follow symlinks if specified on command-line
  if ($follow_symlinks == 1) {
    $rule->extras({follow_fast => 1, follow_skip => 2});
  }

  # iterate over matching files
  $rule = $rule->start( @scan_dirs );
  while (defined ( my $matching_file = $rule->match )) {
    # store the match in our global hash
    addToIndex($matching_file);

    # update the depth-range where we find stuff
    my $depth = $matching_file =~ tr/\//\//;
    if ($depth > $log_deepest_find_depth) {
      $log_deepest_find_depth = $depth;
    }
    if ($depth < $log_shallowest_find_depth) {
      $log_shallowest_find_depth = $depth;
    }
  }

  # remove (potentially outdated/stale) links from previous run.
  clearOldLinksIn($link_dir_path);

  # make found/desired files accessible in www-directory
  #
  # SECURITY IMPLICATIONS: by only providing links to specific files
  #   we save ourselves the problem of making the ENTIRE project hierarchy
  #   available over www, thus limiting our security risk
  makeAllFileSystemLinks($link_dir_path, %bambai_file_index);

  # static html page linking to lsdf-files in IGV-external-control format
  makeHtmlPage($output_file_path, $link_dir_url, $project_name, %bambai_file_index);

  #feedback for poor admin
  printReport();
}


# Registers the provided filename in the global var %bambai_file_index
# under the appropriate group derived from the filepath.
sub addToIndex ($) {
  my ($file) = @_;

  # extract the group label from the identifier
  #  this is either a regex-match, or the catch-all group 'unsorted files'
  my $group_id = deriveGroupIdFrom($file);
  # append the file-path to our list of files-per-group
  $bambai_file_index{$group_id} = [] unless defined $bambai_file_index{$group_id};
  push @{ $bambai_file_index{$group_id} }, $file;

  # Check for data "hotness": when was our dataset of interest last changed?
  #  (i.e. how regularly should I re-run this script?)
  my $mtime = stat($file)->mtime;
  if ($mtime > $log_last_modification_time) {
    $log_last_modification_time = $mtime;
  }
}


# Function to derive a group label from a filepath
#
# requires global var $grouping_regex, a regex whose first capture-group becomes the returned grouping label.
# If no match is found, returns 'ERROR-NO-MATCH' to signal failure.
sub deriveGroupIdFrom ($) {
  my ($filepath) = @_;

  if ($filepath =~ /$grouping_regex/x) {
    my $group_id = $1;
    return $group_id;
  } else {
    push @log_ungroupable_paths, $filepath;
    return '~ unsorted files'; # '~' so it sorts at the end below all detectable groups
  }
}


# recursively clears all links from a directory, and then all empty dirs.
# This should normally clear a link-dir made by this script, but nothing else.
# sanity-checks the provided directory to match "$host_base_dir/*/links", to avoid "find -delete" mishaps
sub clearOldLinksIn ($) {
  my ($dir_to_clear) = @_;

  print "Clearing out links in $dir_to_clear\n";

  # sanity, don't let this work on directories that aren't ours
  # intentionally hardcoding 'links' instead of $siteconfig{'link_dir'}, so it'll break if future people are careless (recursive "find -delete" is NASTY)
  my $pattern = qr/^${siteconfig{'host_base_dir'}}\/.+\/links/;
  die "SAFETY ABORT: parameters specify invalid directory to clear: $dir_to_clear" unless $dir_to_clear =~ $pattern;

  # delete all symlinks in our directory
  system( "find -P '$dir_to_clear' -mount -depth -type l  -delete" );
  # clear out all directories that are now empty (or contain only empty directories -> '-p')
  # pipe to /dev/null because this way (-p: delete recursively-empty dirs in one go) produces a lot of "subdir X no longer exists"-type warnings
  system( "find -P '$dir_to_clear' -mount -depth -type d  -exec rmdir -p {} + 2> /dev/null" );
}


# Populates the publicly-visible public_link_dir with links into the 'private' filesystem.
# One subfolder per group, containing all links associated with that group:
#
# public_link_dir/
#   group_a/
#     some-link-1 -> actual_datafile_1
#     some-link-2 -> actual_datafile_2
#   group_b/
#     some-link-3 -> actual_datafile_3
#     some-link-4 -> actual_datafile_4
#
# SECURITY CONSIDERATION: Working with links into the actual data folders allows us
# to NOT expose the entire big storage in the server's document root, limiting
# the impact of any data breaches. Instead of the entire storage, they see only the
# IGV-relevant files.
sub makeAllFileSystemLinks ($%) {
  my ($public_link_dir, %files_per_group_id) = @_;

  print "creating links in     $public_link_dir\n";

  foreach my $group_id (keys %files_per_group_id) {
    foreach my $file_to_link (@{ $files_per_group_id{$group_id} }) {
      my $link_name = getLinkNameFor($group_id, $file_to_link);
      my $public_path = catfile($public_link_dir, $link_name);     # absolute path of $link_name

      # The generated $link_name will probably contain new sub-directories, create those
      my ($ignored_volume, $link_dir, $ignored_basename) = File::Spec->splitpath($public_path);  # effectively: `dirname $public_path`
      mkpath($link_dir) unless -d $link_dir;

      # Check if the link we want to create was already made for another file in this group;
      # This can't be from a previous run because this parent dir is always cleared by clearOldLinksIn()
      if (-l $public_path) {
        my $old_target = readlink $public_path;
        push @log_symlink_clashes, "$old_target -> $file_to_link";
      }

      symlink $file_to_link, $public_path;
    }
  }
}


sub getDisplayNameFor ($) {
  my ($filepath) = @_;

  if ($display_mode eq "fullpath") {
    return $filepath;

  } elsif ($display_mode eq "nameonly") {
    my ($volume, $dir, $filename) = File::Spec->splitpath($filepath);
    return $filename;

  } else { # we must have a regex in $display_regex, use it
    my @display_items = ($filepath =~ $display_regex);

    # if the display_regex contains unused capture groups (e.g. the 'wrong' branch of alternations), they emit unitialized captures in their result.
    # to prevent "use of uninitialized value" for each and every processing of such a result, strip any uninitialized captures
    @display_items = grep { defined } @display_items;

    if (scalar @display_items != 0) {
      return join('&nbsp;&raquo;&nbsp;', @display_items);
    } else { # paths we can't display nicely, we just display it in all their horrid glory
      push @log_undisplayable_paths, $filepath;
      return $filepath;
    }
  }
}


# Determines a publicly visible name for an absolute filepath.
#
# This subroutine handles all logic of turning a crawled (absolute) file into a new (relative) path fit for public consumption.
# The path is relative so this subroutine can be used by both the filesystem-handling and the URL-handling parts of the code.
# either prepend the www-host dir, or the www-host URL, and you're set to go!
sub getLinkNameFor ($$) {
  my ($group, $filepath) = @_;

  # We DON'T want to re-create the entire project folder structure on the server-side.
  # We DO want to keep the basename of the file, because this is shown in IGV's GUI as track name.
  # Compromise: 3 subdirs
  #   1) group everything per group (for order)
  #   2) condense the entire parent structure into one subdir level (to avoid clashes between identically-named files in different subdirs)
  #         NB: this 'leaks' information on our directory structure.
  #   3) keep the file's basename (for best representation as IGV track name)
  my ($ignored_volume, $parent_dirs, $basename) = File::Spec->splitpath($filepath);
  my @path_elems = grep { $_ ne '' } File::Spec->splitdir($parent_dirs); # splitdir produces leading and trailing ''
  my $anti_clash_path = join(".", @path_elems);

  return catfile($group, $anti_clash_path, $basename);
}


# Formats and pours the provided data into a nice little template. Writes the result to disk.
sub makeHtmlPage ($$$%) {
  my ($output_file, $file_host_dir, $project_name, %files_per_group_id) = @_;

  # Get the HTML template from this file's DATA section
  my $html = do { local $/; <DATA> };
  my $template = HTML::Template->new(
    scalarref         => \$html,
    global_vars       => 1 # needed to make outer-var file_host_dir visible inside per-group loops for links
  );

  # remove clutter: filter out the index files so they won't be explicitly listed in the HTML
  # IGV will figure out the index-links itself from the corresponding non-index filename
  my %nonIndexFiles = findDatafilesToDisplay(%files_per_group_id);

  my $formatted_groups = formatGroupDataForTemplate(%nonIndexFiles);
  my $formatted_scandirs = [ map { {dir => $_} } @scan_dirs ];
  # for some reason, writing 'localtime' directly in the param()-map didn't work, so we need a temp-var
  my $timestamp = localtime;

  # insert everything into the template
  $template->param(
    project_name  => $project_name,
    contact_email => $siteconfig{'contact_email'},
    timestamp     => $timestamp,
    file_host_dir => $file_host_dir,
    groups        => $formatted_groups,
    scandirs      => $formatted_scandirs
  );

  writeContentsToFile($template->output(), $output_file);
}


# Finds all datafiles that should be listed in the html
#
# namely:
# - .bam's having .bai's
# - .bam's having .bam.bai's
# - .tdf files created by igvtools
#
# any index-files (.bai's, .bam.bai's) are not explicitly listed in the html-output.
# Their links already exist by this point though, (see sub makeAllFileSystemLinks),
# so IGV can derive the index-file link from the data-file link (IGV's preferred method).
sub findDatafilesToDisplay (%) {
  my (%original) = @_;

  my %filtered = ();

  foreach my $group_id (keys %original) {
    # meaningful temp names
    my @all_files_of_group = sort @{ $original{ $group_id }};

#TODO #12: invert this: filter out the index-files from the total instead of everything-but-the-indices; will be shorter and less grepping
    my @bams_having_indices = findBamfilesToDisplay(\@all_files_of_group);
    my @attrtxt       = findFilesWithExtension('attr.txt',  \@all_files_of_group);
    my @bed           = findFilesWithExtension('bed',       \@all_files_of_group);
    my @bedgraph      = findFilesWithExtension('bedGraph',  \@all_files_of_group);
    my @bigbed        = findFilesWithExtension('bigbed',    \@all_files_of_group);
    my @bb            = findFilesWithExtension('bb',        \@all_files_of_group);
    my @bigwig        = findFilesWithExtension('bigWig',    \@all_files_of_group);
    my @bw            = findFilesWithExtension('bw',        \@all_files_of_group);
    my @birdsuite     = findFilesWithExtension('birdseye_canary_calls', \@all_files_of_group);
    my @broadpeak     = findFilesWithExtension('broadPeak', \@all_files_of_group);
    my @cbs           = findFilesWithExtension('cbs',       \@all_files_of_group);
    my @cn            = findFilesWithExtension('cn',        \@all_files_of_group);
    my @gct           = findFilesWithExtension('gct',       \@all_files_of_group);
    my @gff           = findFilesWithExtension('gff',       \@all_files_of_group);
    my @gff3          = findFilesWithExtension('gff3',      \@all_files_of_group);
    my @gtf           = findFilesWithExtension('gtf',       \@all_files_of_group);
    my @gistic        = findFilesWithExtension('gistic',    \@all_files_of_group);
    my @igv           = findFilesWithExtension('igv',       \@all_files_of_group);
    my @loh           = findFilesWithExtension('loh',       \@all_files_of_group);
    my @maf           = findFilesWithExtension('maf',       \@all_files_of_group);
    my @mut           = findFilesWithExtension('mut',       \@all_files_of_group);
    my @narrowpeak    = findFilesWithExtension('narrowPeak',\@all_files_of_group);
    my @psl           = findFilesWithExtension('psl',       \@all_files_of_group);
    my @res           = findFilesWithExtension('res',       \@all_files_of_group);
    my @seg           = findFilesWithExtension('seg',       \@all_files_of_group);
    my @snp           = findFilesWithExtension('snp',       \@all_files_of_group);
    my @tdf           = findFilesWithExtension('tdf',       \@all_files_of_group);
    my @wig           = findFilesWithExtension('Wig',       \@all_files_of_group);

    my @combined_result = sort(@bams_having_indices, @attrtxt, @bed, @bedgraph, @bigbed, @bb, @bigwig, @bw, @birdsuite, @broadpeak,
                           @cbs, @cn, @gct, @gff, @gff3, @gtf, @gistic, @igv, @loh, @maf, @mut, @narrowpeak, @psl, @res,
                           @seg, @snp, @tdf, @wig);

    # update totals-counter
    $log_total_files_displayed += (scalar @combined_result);

    # store result, if we have any visible files remaining
    # This means we don't show groups who have no data files.
    # (though they may still have orphaned index files)
    if (scalar(@combined_result) > 0) {
      @{ $filtered{ $group_id } } = @combined_result;
    }
  }

  # update other totals-counter
  $log_total_groups_displayed = scalar keys %filtered;

  return %filtered;
}


# filters a group's files for bams having .bai or .bam.bai files
sub findBamfilesToDisplay ($) {
    my ($all_files_of_group_ref) = @_;
    my @all_files_of_group = @$all_files_of_group_ref;
    my @unfiltered_bams = grep { $_ =~ /\.bam$/  } @all_files_of_group;

    # actual filtering steps
    my @bams_having_bais    = findFilesWithIndices('.bam', '.bai',     \@all_files_of_group);
    my @bams_having_bambais = findFilesWithIndices('.bam', '.bam.bai', \@all_files_of_group);

    # merge results, removing duplicates (some .bams provide both .bai + .bam.bai, and so occur in both bams_having_X lists)
    my %unique_merged_bams_having_indices = map { $_, 1 } (@bams_having_bais, @bams_having_bambais);
    my @bams_having_indices = sort keys %unique_merged_bams_having_indices;

    # log missing indices for report
    my @bams_missing_indices = grep { not $_ ~~ @bams_having_indices } @unfiltered_bams;
    push @log_files_without_indices, @bams_missing_indices;

    return @bams_having_indices;
}


# finds files ending in .<parameter>$ among a group's files
# extension is match as case-insensitive regex.
sub findFilesWithExtension ($$) {
  my ($extension, $all_files_of_group_ref) = @_;
  my @all_files_of_group = @$all_files_of_group_ref;

  my $extension_pattern = '\.' . quotemeta($extension) . '$';

  return grep { $_ =~ /$extension_pattern/i } @all_files_of_group;
}


# returns a list of the datafiles that have a matching index-file
#
# i.e. given a list of found datafiles+indexfiles
# returns the list of datafiles that have an indexfile in the input
# effectively removing both indexless-datafiles AND the indexfiles from the input
sub findFilesWithIndices ($$$) {
  #       .bam       , .bam.bai || .bai,   [....]
  my ($data_extension, $index_extension, $all_files_of_group_ref) = @_;
  my @all_files_of_group = @$all_files_of_group_ref;

  my $data_pattern  = quotemeta($data_extension)  . '$';
  my $index_pattern = quotemeta($index_extension) . '$';

  # first, divide our datafiles and indexfiles into separate buckets
  my @found_data    = grep { $_ =~ /$data_pattern/  } @all_files_of_group;
  my @found_indices = grep { $_ =~ /$index_pattern/ } @all_files_of_group;

  # second, map each datafile to its _expected_ indexfile
  my %expected_indices = map {
    my $found_data = $_;

    my $expected_index = $found_data;
    $expected_index =~ s/$data_pattern/$index_extension/;

    # 'return' map k,v pair
    # NOTE: key,value swapped in counterintuitive way for cleverness below
    {$expected_index => $found_data}
  } @found_data;

  # finally: be clever :-)
  # delete the found index-files from expected-index-files map;
  #   since "delete ASSOC_ARRAY" returns the associated values of all deleted keys
  #   (i.e. the datafile attached to each found-index-file, thanks to the 'inverted' key,value from before)
  #   this immediately gives us a list of all datafiles which have a corresponding indexfile
  my @data_having_index = delete @expected_indices{@found_indices};
  # %expected_indices now contains the hash { missing-index-file => found-data-file }
  #   unfortunately, we cannot use this to detect data-files-missing-their-index, because
  #   file.bam could be missing file.bam.bai, while having file.bai (which is considered in a different calling of this funtion)

  # remove undefs resulting from leftover index-files whose data-file was removed/not-found
  # (removing non-existant keys returns an undef)
  @data_having_index = grep { defined } @data_having_index;

  return @data_having_index;
}


# prepares datastructure to insert into template
#
# it creates the nested structure for the list-of-(groups-with-list-of-their-files)
# formatted as a nested list-of-maps, suitable for HTML::Template
# [
#  {
#    group_id => "group_1",
#    linked_files => [
#      { diskfilename => "file1", displayfilename => "[analysis] /some/folder/file1" },
#      { diskfilename => "file2", displayfilename => "[analysis] /some/folder/file2" },
#      ...
#    ]
#  },
# ...]
#
sub formatGroupDataForTemplate (%) {
  my %files_per_group = @_;

  # sorry for the next unreadable part!
  return [ map {
    # outer 'list' of group + linked-files
    my $group = $_;
    {
      group_id    => $group,
      linked_files  => [ map {
        # inner 'list' of filenames
        my $filename = $_;
        {
          diskfilename    => getLinkNameFor($group, $filename),
          displayfilename => getDisplayNameFor($filename)
        }
      } @{$files_per_group{$group}} ]
    }
  } (sort keys %files_per_group) ];
}


sub writeContentsToFile ($$) {
  my ($contents, $filename) = @_;

  print "writing contents to   $filename\n";
  open (FILE, "> $filename") or die "problem opening $filename\n";
  print FILE $contents;
  close (FILE);
}


sub printReport () {
  print "\n== After-action report for $project_name ==\n";

  # log once to STDOUT, in long or short form depending on CLI input ...
  if ($report_mode eq "counts") {
    printShortReport();
  } elsif ($report_mode eq "full") {
    printLongReport(*STDOUT);
  }

  # .. and also log (always long-form) to a file
  # make sure we don't need subdirs in the log-dir (project names may contain slashes to create reports in subdirs)
  (my $safe_project_name = $project_name) =~ s/\//_/;
  my $log_file = catfile($siteconfig{'log_dir'}, $safe_project_name . ".log");
  my $success = open( my $fh, ">", $log_file);
  if ($success) {
    printLongReport($fh);
  } else {
    warn "Couldn't open $log_file for writing";
  }
}


sub printShortReport () {
  print "total files scanned (excl. unreadable): " .        $log_total_files_scanned    . "\n" .
        "total groups displayed:                 " .        $log_total_groups_displayed . "\n" .
        "total files displayed:                  " .        $log_total_files_displayed  . "\n" .
        "deepest directory scanned:              " .        $log_deepest_scan_depth     . "\n" .
        "deepest file found:                     " .        $log_deepest_find_depth     . "\n" .
        "shallowest file found:                  " .        $log_shallowest_find_depth  . "\n" .
        "ignored files:                          " .        $log_ignored_files          . "\n" .
        "ungroupable paths:                      " . scalar @log_ungroupable_paths      . "\n" .
        "files skipped for missing index:        " . scalar @log_files_without_indices  . "\n" .
        "symlink clashes:                        " . scalar @log_symlink_clashes        . "\n" .
        "unreadable files:                       " . scalar @log_unreadable_paths       . "\n" .
        "most recently changed file in index:    " . time2str("%Y-%m-%d %H:%M:%S%n", $log_last_modification_time) . "\n";

  print "unparseable paths:                      " . scalar @log_undisplayable_paths    . "\n" if $display_mode eq 'regex';
}


sub printLongReport ($) {
  my ($fh) = @_;

  print $fh "total files scanned (excl. unreadable): $log_total_files_scanned\n" .
            "total groups displayed:                 $log_total_groups_displayed\n" .
            "total files displayed:                  $log_total_files_displayed\n".
            "deepest directory scanned (from / ):    $log_deepest_scan_depth\n" .
            "deepest file found        (from / ):    $log_deepest_find_depth\n" .
            "shallowest file found     (from / ):    $log_shallowest_find_depth\n" .
            "ignored files:                          $log_ignored_files\n" .
            "most recently changed file in index:    " . time2str("%Y-%m-%d %H:%M:%S", $log_last_modification_time) . "\n";

  printWithHeader($fh, "ungroupable paths",      \@log_ungroupable_paths);
  printWithHeader($fh, "files without index",    \@log_files_without_indices);
  printWithHeader($fh, "symlink name clashes",   \@log_symlink_clashes);

  printWithHeader($fh, "unreadable paths",       \@log_unreadable_paths);

  my @parsed_unreadable_summary = map {
      $log_unreadable_summary{$_} > 1 ?
         sprintf("%-25s % 4d", ($_ . ':'), $log_unreadable_summary{$_})
         : ()
  } keys %log_unreadable_summary;
  printWithHeader($fh, "Recurring unreadable subdirectories", \@parsed_unreadable_summary);

  printWithHeader($fh, "Unparseable paths",      \@log_undisplayable_paths) if $display_mode eq 'regex';
}


sub printWithHeader ($$$) {
  my ($fh, $header, $reflist) = @_;
  my @list = @{$reflist};

  my $count = scalar @list;

  if ($count == 0) {
    # print shorter form if there's no list
    print $fh sprintf("%-40s0\n", ($header . ':'));
  } else {
    # print full list
    my $indent = "  ";
    print $fh "=== $count $header ===";
    print $fh "\n$indent" . join("\n$indent", sort @list) . "\n";
  }
}


# END FUNCTION DEFINITIONS ########################################################

###################################################################################
# Data section: the HTML::Template to be filled in by the code
__DATA__
<html>
<head>
  <title><!-- TMPL_VAR NAME=project_name --> IGV linker</title>
  <style type="text/css" media="screen"><!--
    /* visual separation of groups */
    H2  {
      background: lightgray;
      margin-top:    1.2em;
      margin-bottom:   0em;
    }
    UL {
      margin-top: 0.7em;   /* draw group-links closer to their heading */
      padding-left: 1.6em; /* reduce indent of bullet points */
    }

    /* reduce visual clutter of links, otherwise 90% of the page is underlined */
    A:link     { text-decoration: none }
    A:visited  { text-decoration: none }
    A:hover    { text-decoration: underline }
    A:active   { text-decoration: underline }
  --></style>

</head>
<body style="margin-right: 280px;">

<h1 id="page-title"><!-- TMPL_VAR NAME=project_name --> IGV linker</h1>

<p id="introduction">
  The IGV-relevant files for the <!-- TMPL_VAR NAME=project_name --> project have been made available online here over a secured connection.<br/>
  Below are some clickable links that will add said files into a running IGV session.<br/>
  Learn more about this functionality at the IGV-website under <a target="blank" href="https://www.broadinstitute.org/software/igv/ControlIGV">controlling IGV</a>
</p>

<p id="igv-instructions">
  <strong>NOTE! the links below only work if</strong>
  <ol>
    <li>IGV is already running on your LOCAL computer</li>
    <li>you enabled port-control (in view > preferences > advanced > enable port > port 60151)</li>
    <li>you have the correct reference genome loaded before clicking the link.<br/>
      (do this before loading files, or all positions will show up as mutated)<br/>
      to add missing genomes to IGV, see menu > genomes > load genome from server<br/>
  </ol>
</p>

<p id="about-blurb"><small>
  IGV-linker v2.0, a service by the eilslabs data management group<br/>
  questions, wishes, improvements or suggestions: <a href="mailto:<!-- TMPL_VAR NAME=contact_email -->"><!-- TMPL_VAR NAME=contact_email --></a><br/>
  powered by <a href="http://www.threepanelsoul.com/comic/on-perl">readable perl&trade;</a><br/>
  last updated: <!-- TMPL_VAR NAME=timestamp --><br/>
  generated from files found in:
  <ul><!-- TMPL_LOOP NAME=scandirs -->
    <li><!-- TMPL_VAR NAME=dir --></li><!-- /TMPL_LOOP -->
  </ul>
</small></p>

<!-- Right-hanging menu: has quick-links to each group header below -->
<div id="group-menu" style="
  position: fixed;
  top: 5px;
  bottom: 5px;
  right: 0px;
  font-size: small;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 4px 28px 4px 6px;
  background-color: white;
  border: 1px solid black;
  border-right: none;
  border-bottom-left-radius: 7px;
  border-top-left-radius: 7px;
  white-space: nowrap;
">
Jump to:
<ul><!-- TMPL_LOOP NAME=groups -->
  <li><a href="#<!-- TMPL_VAR NAME=group_id -->"><!-- TMPL_VAR NAME=group_id --></a></li><!-- /TMPL_LOOP --></ul>
</div>

<h1>IGV files</h1>
<!-- TMPL_LOOP NAME=groups -->
  <h2 id="<!-- TMPL_VAR NAME=group_id -->"><!-- TMPL_VAR NAME=group_id --></h2>
  <ul class="files"><!-- TMPL_LOOP NAME=linked_files -->
    <li><a href="http://localhost:60151/load?file=<!-- TMPL_VAR NAME=file_host_dir -->/<!-- TMPL_VAR NAME=diskfilename -->"><!-- TMPL_VAR NAME=displayfilename --></a></li><!-- /TMPL_LOOP -->
  </ul>
<!-- /TMPL_LOOP -->
<hr>
<p><small>The end, thank you for reading!</small></p>
</body>
</html>

