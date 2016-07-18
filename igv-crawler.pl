#!/usr/bin/env perl
use strict;
use warnings;
use 5.010;

#
# This script scans the specified project folder for
# folders containing <samplename>.bam + <samplename>.bai
# All such bam+bai-files will be linked in the specified output dir
# Additionally it will make a .html index page for users to browse.
#
# Some more documentation at xWiki:
# https://ibios.dkfz.de/xwiki/bin/view/Database/Making+%28OTP%29+BamFiles+available+online

use File::Find;
use File::Path;
use File::Spec::Functions;
use HTML::Template;
use Getopt::Long;
use Data::Dumper;


#####################################################################################
# CONSTANTS
#

# the local FS dir where apache looks for stuff to host
#   script will create subdirs in it named 'lc $project_name'
#   (must have trailing slash!)
my $host_base_dir = "/public-otp-files/";

# the externally visible URL for $host_base_dir (NO TRAILING SLASH!)
my $www_base_url  = "https://otpfiles.dkfz.de";

# subdir name inside $host_base_dir where to store symlinks for both file-system and URL
my $link_dir = "links";

my $log_dir = "/home/icgcdata/logs";

# END CONSTANTS #####################################################################


#####################################################################################
# COMMAND LINE PARAMETERS
#
my $project_name = 'demo';        # defaults to demo-settings, to not-break prod when someone forgets to specify
my @scan_dirs;                    # list of directories that will be scanned
my $pid_regex;                    # every file-path is run through this regex to extract the PID (pid-pattern MUST be first capture group)
my $display_mode = "nameonly";    # what to show in the HTML-file; defaults to historical behaviour: show filename without parent dir-path
my $display_regex;                # parsed version of $display_mode, in case it is a regex
my $report_mode = "counts";       # what to report? "full" > print complete lists of paths, "counts" > only print number of files/paths
my $follow_symlinks = 0;          # whether to follow symlinks (use of this option breaks logging of unreadable directories, due to limitations on the 'preprocess' funtion in File::Find http://perldoc.perl.org/File/Find.html)
#####################################################################################
# REPORTING VARIABLES
# We keep some counters/lists to see what kinds of trouble we run in to.
#
my $log_total_files_scanned = 0;  # total number of files seen by the find-filter (excludes unreadable directories)
my $log_total_files_displayed =0; # number of files that are displayed
my $log_total_pids_displayed =0;  # number of distinct patients all the files belong to
my @log_undisplayable_paths;      # paths that didn't match the displaymode=regex parsing; what should we improve in the display-regex?
my @log_symlink_clashes;          # Currently filenames must be unique per pid, because the symlink uses only the basename; log if this causes problems (fix to come?)
my @log_pid_undetectable_paths;   # paths that we couldn't derive a pid from
my @log_files_without_indices;    # files we had to filter out due to missing indices
my @log_orphaned_indices;         # leftover index-files we found, whose datafile was removed
#####################################################################################

# THE var: global list to keep track of all the bam+bai files we have found
# format:
# {
#   'patientId1' => [ '/some/file/path.bam', 'some/file/path.bai', ...],
#   'patientId2' => [ '/other/file/path.bam', 'some/other/path.bai', ...],
# }
#
# Sadly must be global, otherwise the File::find callback (igvFileFilter) can't add to it
my %bambai_file_index = ();



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
              'pidformat=s' => \$pid_regex,      # the regex used to extract the patient_id from a file path.
              'display=s'   => \$display_mode,   # either the keyword "nameonly" or "fullpath", or a regex whose capture-groups will be listed.
              'report=s'    => \$report_mode,    # what to report at end-of-execution: "counts" or "full"
              'followlinks' => \$follow_symlinks # flag, follow symlinks or not?
             )
  or die("Error parsing command line arguments");

  # sanity check: project name?
  die 'No project name specified, aborting!' if ($project_name eq '');

  # sanity check: pid-format
  die "Didn't specifify pid-format, cannot extract patient ID from file paths, aborting!" if ($pid_regex eq "");

  # sanity check: display mode
  if ($display_mode =~ /^regex=(.*)/) {
    $display_mode = 'regex';
    $display_regex = $1;
    if (index($display_regex, '(') == -1) {   # yes, a crafty user could fool this with (?:), but then you're intentionally messing it up
      die "display-mode regex must contain at least one capture group to display";
    }
    eval {
      $display_regex = qr/$display_regex/; # precompile regex
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
  
  my $project_name_lower = lc $project_name;
  my $output_file_path   = catfile( $host_base_dir, $project_name_lower, "index.html");
  my $link_dir_path      = catdir ( $host_base_dir, $project_name_lower, $link_dir);
  my $link_dir_url       = $www_base_url . "/" . $project_name_lower . "/" . $link_dir; # trailing slash is added in __DATA__ template

  return ($link_dir_path, $link_dir_url, $output_file_path)
}


sub main {
  my ($link_dir_path, $link_dir_url, $output_file_path) = parseArgs();

  print "Scanning $project_name for IGV-relevant files in:\n";
  print "  $_\n" for @scan_dirs;

  # Follow symlinks or not?
  my ($follow_fast, $follow_skip) = (undef, undef); # default: don't follow anything
  if ($follow_symlinks == 1) {
    ($follow_fast, $follow_skip) = (1, 2)  # (follow symlinks, silently ignore duplicate files)
  }

  finddepth( {
      wanted => \&igvFileFilter, # uses globals! stores into global %bambai_file_index, via sub addToIndex()
      follow_fast => $follow_fast, follow_skip => $follow_skip
  }, @scan_dirs);

  # remove (potentially outdated/stale) links from previous run.
  clearOldLinksIn($link_dir_path);

  # make desired LSDF files accessible in www-directory
  makeAllFileSystemLinks($link_dir_path, %bambai_file_index);

  # static html page linking to lsdf-files in IGV-external-control format
  makeHtmlPage($output_file_path, $link_dir_url, $project_name, %bambai_file_index);

  #feedback for poor admin
  printReport();
}


# Used by File::Find::finddepth in main()
# It determines if a file is relevant to IGV (either a file to display, or an accompanying index-file).
# If so, the file is added to the global list via sub addToIndex()
sub igvFileFilter () {
  $log_total_files_scanned++;
  my $filename = $File::Find::name;

  # fail-fast on simple cases.
  return undef if -d $filename;   # skip directories, they're crawled, but never indexed
  return undef if -z $filename;   # skip empty/zero-size files

  # file-types we're actually interested in.
  # based on IGV's supported file formats: https://www.broadinstitute.org/software/igv/FileFormats
  if (
    $filename =~ /\.ba[im]$/                 or
    $filename =~ /\.bed$/                    or
    $filename =~ /\.bedGraph$/               or
    $filename =~ /\.bigbed$/                 or
    $filename =~ /\.bigWig$/                 or
    $filename =~ /\.birdseye_canary_calls$/  or
    $filename =~ /\.broadPeak$/              or
    $filename =~ /\.cbs$/                    or
    $filename =~ /\.cn$/                     or
    $filename =~ /\.gct$/                    or
    $filename =~ /\.gff$/                    or
    $filename =~ /\.gff3$/                   or
    $filename =~ /\.gtf$/                    or
    $filename =~ /\.gistic$/                 or
    $filename =~ /\.loh$/                    or
    $filename =~ /\.maf$/                    or
    $filename =~ /\.mut$/                    or
    $filename =~ /\.narrowPeak$/             or
    $filename =~ /\.psl$/                    or
    $filename =~ /\.res$/                    or
    $filename =~ /\.seg$/                    or
    $filename =~ /\.snp$/                    or
    $filename =~ /\.tdf$/                    or
    $filename =~ /\.tbi$/                    or
    $filename =~ /\.wig$/
  ) {
    addToIndex($filename);
  }

  # and we're done, but File::Find doesn't expect a return value.
  return undef;
}


# Registers the provided filename in the global var %bambai_file_index
# under the appropriate PID derived from the filepath.
sub addToIndex ($) {
  my ($file) = @_;

  # extract the patient ID from the identifier
  my $patient_id = derivePatientIdFrom($file);
  if ($patient_id ne 'ERROR-NO-MATCH') {
    # append the file-path to our list of files-per-patient
    $bambai_file_index{$patient_id} = [] unless defined $bambai_file_index{$patient_id};
    push @{ $bambai_file_index{$patient_id} }, $file;
  }
}


# Function to derive a patientID from a filename
# requires global var $pid_regex, a regex whose first capture-group becomes the returned pid.
# If no match is found, returns 'ERROR-NO-MATCH' to signal failure.
sub derivePatientIdFrom ($) {
  my ($filepath) = @_;

  if ($filepath =~ /$pid_regex/) {
    my $patient_id = $1;
    return $patient_id;
  } else {
    push @log_pid_undetectable_paths, $filepath;
    return 'ERROR-NO-MATCH';
  }
}


# recursively clears all links from a directory, and then all empty dirs.
# This should normally clear a link-dir made by this script, but nothing else.
# sanity-checks the provided directory to match /public-otp-files/*/links, to avoid "find -delete" mishaps
sub clearOldLinksIn ($) {
  my ($dir_to_clear) = @_;

  print "Clearing out links and empty directories in $dir_to_clear\n";

  # sanity, don't let this work on directories that aren't ours
  # intentionally hardcoding 'links' instead of $link_dir, so it'll break if future people are careless (recursive "find -delete" is NASTY)
  die "SAFETY: paramaters specify invalid directory to clear: $dir_to_clear" unless $dir_to_clear =~ /^\/public-otp-files\/.*\/links/;

  # delete all symlinks in our directory
  system( "find -P '$dir_to_clear' -mount -depth -type l  -delete" );
  # clear out all directories that are now empty (or contain only empty directories -> '-p')
  # pipe to /dev/null because this way (-p: delete recursively-empty dirs in one go) produces a lot of "subdir X no longer exists"-type warnings
  system( "find -P '$dir_to_clear' -mount -depth -type d  -exec rmdir -p {} + 2> /dev/null" );
}


# Populates the publicly-visible public_link_dir with links into the 'private' filesystem.
# One subfolder per PID containing all links for that patient:
#
# public_link_dir/
#   pid_a/
#     some-link-1
#     some-link-2
#   pid_b/
#     some-link-3
#     some-link-4
#
sub makeAllFileSystemLinks ($%) {
  my ($public_link_dir, %files_per_patient_id) = @_;

  print "creating links in $public_link_dir\n";

  foreach my $patient_id (keys %files_per_patient_id) {
    my $public_pid_dir = makeDirectoryFor($public_link_dir, $patient_id);
    foreach my $file_to_link (@{ $files_per_patient_id{$patient_id} }) {
      my $filename = getLinkNameFor($file_to_link);

      my $public_path = catfile($public_pid_dir, $filename);
      if (-l $public_path) { # the link we want to create was already made for another file in this pid; this isn't from a previous run because this parent dir is cleared by clearOldLinksIn() before this
        my $old_target = readlink $public_path;

        push @log_symlink_clashes, "$old_target -> $file_to_link";
      }

      symlink $file_to_link, $public_path;
    }
  }
}


sub makeDirectoryFor ($$) {
  my ($link_target_dir, $patient_id) = @_;

  my $path = catfile($link_target_dir, $patient_id);
  mkpath($path) unless -d $path;

  return $path;
}


sub getDisplayNameFor ($) {
  my ($filepath) = @_;

  if ($display_mode eq "fullpath") {
    return $filepath;

  } elsif ($display_mode eq "nameonly") {
    my ($volume, $dir, $filename) = File::Spec->splitpath($filepath);
    return $filename;

  } else { # we must have a regex in $display_regex, use it
    # example path:  /icgc/dkfzlsdf/analysis/hipo/hipo_035/data_types/ChIPseq_v4/results_per_pid/H035-137M/alignment/H035-137M.cell04.H3.sorted.bam
    # example regex: /icgc/dkfzlsdf/(analysis|project)/hipo/(hipo_035)/data_types/([-_ \w\d]+)/(?:results_per_pid/)*(.+)
    my @captures = ($filepath =~ $display_regex);
    if (scalar @captures != 0) {
      return join(" > ", @captures);

    } else { # paths we can't display nicely, we just display it in all their horrid glory
      push @log_undisplayable_paths, $filepath;
      return $filepath;
    }
  }
}


# Determines a publicly visible name for an absolute filepath.
# It mostly just flattens directory separators to dashes:
# /my/absolute/results-per-pid-scandir/some_pid/some_analysis/file.txt becomes
# -my-absolute-results-per-pid-scandir-some_pid-some_analysis-file.txt
sub getLinkNameFor ($) {
  my ($filepath) = @_;

  # avoid turning the links-per-pid subdir into a maze of subdirs
  # just keep a flat list of links under there.
  # i.e. some/dir/with/a-file.txt -> some-dir-with-a-file.txt
  my ($volume, $dir, $filename) = File::Spec->splitpath($filepath);
  my @path_elems = File::Spec->splitdir($dir);
  push @path_elems, $filename;
  return join("-", @path_elems);
}


# Formats and pours the provided data into a nice little template. Writes the result to disk.
sub makeHtmlPage ($$$%) {
  my ($output_file, $file_host_dir, $project_name, %files_per_patient_id) = @_;

  # Get the HTML template
  my $html = do { local $/; <DATA> };
  my $template = HTML::Template->new(
    scalarref         => \$html,
    global_vars       => 1 # needed to make outer-var file_host_dir visible inside per-patient loops for links
  );

  # remove clutter: filter out the index files so they won't be explicitly listed in the HTML
  # IGV will figure out the index-links itself from the corresponding non-index filename
  my %nonIndexFiles = findDatafilesToDisplay(%bambai_file_index);

  my $formatted_patients = formatPatientDataForTemplate(%nonIndexFiles);
  my $formatted_scandirs = [ map { {dir => $_} } @scan_dirs ];
  # for some reason, writing 'localtime' directly in the param()-map didn't work, so we need a temp-var
  my $timestamp = localtime;

  # insert everything into the template
  $template->param(
    project_name  => $project_name,
    timestamp     => $timestamp,
    file_host_dir => $file_host_dir,
    patients      => $formatted_patients,
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

  foreach my $patient_id (keys %original) {
    # meaningful temp names
    my @all_files_of_patient = sort @{ $original{ $patient_id }};

    my @bams_having_indices = findBamfilesToDisplay(@all_files_of_patient);
    my @bed           = findFilesWithExtension('bed',       @all_files_of_patient);
    my @bedgraph      = findFilesWithExtension('bedGraph',  @all_files_of_patient); 
    my @bigbed        = findFilesWithExtension('bigbed',    @all_files_of_patient);
    my @bigwig        = findFilesWithExtension('bigWig',    @all_files_of_patient);
    my @birdsuite     = findFilesWithExtension('birdseye_canary_calls', @all_files_of_patient); 
    my @broadpeak     = findFilesWithExtension('broadPeak', @all_files_of_patient); 
    my @cbs           = findFilesWithExtension('cbs',       @all_files_of_patient);
    my @cn            = findFilesWithExtension('cn',        @all_files_of_patient);
    my @gct           = findFilesWithExtension('gct',       @all_files_of_patient);
    my @gff           = findFilesWithExtension('gff',       @all_files_of_patient);
    my @gff3          = findFilesWithExtension('gff3',      @all_files_of_patient);
    my @gtf           = findFilesWithExtension('gtf',       @all_files_of_patient);
    my @gistic        = findFilesWithExtension('gistic',    @all_files_of_patient);
    my @loh           = findFilesWithExtension('loh',       @all_files_of_patient);
    my @maf           = findFilesWithExtension('maf',       @all_files_of_patient);
    my @mut           = findFilesWithExtension('mut',       @all_files_of_patient);
    my @narrowpeak    = findFilesWithExtension('narrowPeak',@all_files_of_patient); 
    my @psl           = findFilesWithExtension('psl',       @all_files_of_patient);
    my @res           = findFilesWithExtension('res',       @all_files_of_patient);
    my @seg           = findFilesWithExtension('seg',       @all_files_of_patient);
    my @snp           = findFilesWithExtension('snp',       @all_files_of_patient);
    my @tdf           = findFilesWithExtension('tdf',       @all_files_of_patient);
    my @wig           = findFilesWithExtension('Wig',       @all_files_of_patient);


    my @combined_result = sort(@bams_having_indices, @bed, @bedgraph, @bigbed, @bigwig, @birdsuite, @broadpeak,
                           @cbs, @cn, @gct, @gff, @gff3, @gtf, @gistic, @loh, @maf, @mut, @narrowpeak, @psl, @res,
                           @seg, @snp, @tdf, @wig);

    # update totals-counter
    $log_total_files_displayed += (scalar @combined_result);

    # store result
    @{ $filtered{ $patient_id } } = @combined_result;
  }

  # update other totals-counter
  $log_total_pids_displayed = scalar keys %filtered;

  return %filtered;
}


# filters a patient's files for bams having .bai or .bam.bai files
sub findBamfilesToDisplay (@) {
    my @all_files_of_patient = @_;
    my @unfiltered_bams = grep { $_ =~ /\.bam$/  } @all_files_of_patient;

    # actual filtering steps
    my @bams_having_bais    = findFilesWithIndices('.bam', '.bai',     @all_files_of_patient);
    my @bams_having_bambais = findFilesWithIndices('.bam', '.bam.bai', @all_files_of_patient);

    # merge results, removing duplicates (some .bams provide both .bai + .bam.bai, and so occur in both bams_having_X lists)
    my %unique_merged_bams_having_indices = map { $_, 1 } (@bams_having_bais, @bams_having_bambais);
    my @bams_having_indices = sort keys %unique_merged_bams_having_indices;

    # log missing indices for report
    my @bams_missing_indices = grep { not $_ ~~ @bams_having_indices } @unfiltered_bams;
    push @log_files_without_indices, @bams_missing_indices;

    return @bams_having_indices;
}


# finds files ending in .<parameter>$ among a patient's files
# extension is match as case-insensitive regex.
sub findFilesWithExtension ($@) {
  my ($extension, @all_files_of_patient) = @_;

  my $extension_pattern = '.' . quotemeta($extension) . '$';
  
  return grep { $_ =~ /$extension_pattern/i } @all_files_of_patient;
}


# returns a list of the datafiles that have a matching index-file
#
# i.e. given a list of found datafiles+indexfiles
# returns the list of datafiles that have an indexfile in the input
# effectively removing both indexless-datafiles AND the indexfiles from the input
sub findFilesWithIndices ($$@) {
  my ($data_extension, $index_extension, @all_files) = @_;
  #       .bam       , .bam.bai || .bai,   [....]

  my $data_pattern  = quotemeta($data_extension)  . '$';
  my $index_pattern = quotemeta($index_extension) . '$';

  # first, divide our datafiles and indexfiles into separate buckets
  my @found_data    = grep { $_ =~ /$data_pattern/  } @all_files;
  my @found_indices = grep { $_ =~ /$index_pattern/ } @all_files;

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
  # TODO: figure out how to log the matching found_index to @log_orphaned_indices
  @data_having_index = grep { defined } @data_having_index;

  return @data_having_index;
}


# prepares patient datastructure to insert into template
#
# it creates the nested structure for the list-of-(patients-with-list-of-their-files)
# formatted as a nested list-of-maps, suitable for HTML::Template
# [
#  {
#    patient_id => "patient_1",
#    linked_files => [
#      { diskfilename => "file1", displayfilename => "[analysis] /some/folder/file1" },
#      { diskfilename => "file2", displayfilename => "[analysis] /some/folder/file2" },
#      ...
#    ]
#  },
# ...]
#
sub formatPatientDataForTemplate (%) {
  my %files_per_pid = @_;

  # sorry for the next unreadable part!
  return [ map {
    # outer 'list' of patient + linked-files
    my $pid = $_;
    {
      patient_id    => $pid,
      linked_files  => [ map {
        # inner 'list' of filenames
        my $filename = $_;
        {
          diskfilename    => getLinkNameFor($filename),
          displayfilename => getDisplayNameFor($filename)
        }
      } @{$files_per_pid{$pid}} ]
    }
  } (sort keys %files_per_pid) ];
}


sub writeContentsToFile ($$) {
  my ($contents, $filename) = @_;

  print "writing contents to $filename\n";
  open (FILE, "> $filename") or die "problem opening $filename\n";
  print FILE $contents;
  close (FILE);
}


sub printReport () {
  print "== After-action report for $project_name ==\n";

  # log once to STDOUT, in long or short form depending on CLI input ...
  if ($report_mode eq "counts") {
    printShortReport();
  } elsif ($report_mode eq "full") {
    printLongReport(*STDOUT);
  }

  # .. and also log (always long-form) to a file
  my $log_file = catfile($log_dir, $project_name . ".log");
  my $success = open( my $fh, ">", $log_file);
  if ($success) {
    printLongReport($fh);
  } else {
    warn "Couldn't open $log_file for writing";
  }
}


sub printShortReport () {
  print "total files scanned (excl. unreadable): " .        $log_total_files_scanned    . "\n" .
        "total patients displayed:               " .        $log_total_pids_displayed   . "\n" .
        "total files displayed:                  " .        $log_total_files_displayed  . "\n" .
        "undetectable pids:                      " . scalar @log_pid_undetectable_paths . "\n" .
        "files skipped for missing index:        " . scalar @log_files_without_indices  . "\n" .
        "symlink clashes:                        " . scalar @log_symlink_clashes        . "\n";

  print "unparseable paths:                      " . scalar @log_undisplayable_paths    . "\n" if $display_mode eq 'regex';
}


sub printLongReport ($) {
  my ($fh) = @_;

  print $fh "total files scanned (excl. unreadable): $log_total_files_scanned\n" .
            "total patients displayed:               $log_total_pids_displayed\n" .
            "total files displayed:                  $log_total_files_displayed\n";

  printWithHeader($fh, "undetectable PIDs",      @log_pid_undetectable_paths);
  printWithHeader($fh, "files without index",    @log_files_without_indices);
  printWithHeader($fh, "symlink name clashes",   @log_symlink_clashes);

  printWithHeader($fh, "Unparseable paths",      @log_undisplayable_paths) if $display_mode eq 'regex';
}


sub printWithHeader ($$@) {
  my ($fh, $header, @list) = @_;
  my $count = scalar @list;

  my $indent = "  ";
  print $fh "=== $count $header ===";
  print $fh "\n$indent" . join("\n$indent", sort @list) . "\n";
}


# END FUNCTION DEFINITIONS ########################################################

###################################################################################
# Data section: the HTML::Template to be filled in by the code
__DATA__
<html>
<head>
  <title>IGV files for <!-- TMPL_VAR NAME=project_name --></title>
  <style type="text/css" media="screen"><!--
    H2  { background: lightgray }
  --></style>

</head>
<body style="padding-right: 280px;">

<h1><!-- TMPL_VAR NAME=project_name --> IGV linker</h1>

<p>
  The IGV-relevant files for the <!-- TMPL_VAR NAME=project_name --> project have been made available online here over a secured connection.<br/>
  Below are some clickable links that will add said files into a running IGV session.<br/>
  Learn more about this functionality at the IGV-website under <a target="blank" href="https://www.broadinstitute.org/software/igv/ControlIGV">controlling IGV</a>
</p>

<p>
  <strong>NOTE! the links below only work if</strong>
  <ol>
    <li>IGV is already running</li>
    <li>you enabled port-control (in view > preferences > advanced > enable port > port 60151)</li>
    <li>you have the correct reference genome loaded before clicking the link.<br/>
      (do this before loading files, or all positions will show up as mutated)<br/>
      to add missing genomes to IGV, see menu > genomes > load genome from server<br/>
  </ol>
</p>

<p id="about-blurb"><small>
  IGV-linker v2.0, a service by the eilslabs data management group<br/>
  questions, wishes, improvements or suggestions: <a href="mailto:j.kerssemakers@dkfz-heidelberg.de">j.kerssemakers@dkfz-heidelberg.de</a><br/>
  powered by <a href="http://www.threepanelsoul.com/comic/on-perl">readable perl&trade;</a><br/>
  last updated: <!-- TMPL_VAR NAME=timestamp --><br/>
  generated from files found in:
  <ul><!-- TMPL_LOOP NAME=scandirs -->
    <li><!-- TMPL_VAR NAME=dir --></li><!-- /TMPL_LOOP -->
  </ul>
</small></p>

<!-- Right-hanging menu: has quick-links to each patient-id header below -->
<div id="menu" style="
  position: fixed;
  top: 5px;
  bottom: 5px;
  right: 0px;
  font-size: small;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 4px 20px 4px 6px;
  background-color: white;
  border: 1px solid black;
  border-right: none;
  border-bottom-left-radius: 7px;
  border-top-left-radius: 7px;
  white-space: nowrap;
">
Jump to:
<ul style="padding-left: 26px;"><!-- TMPL_LOOP NAME=patients -->
  <li><a href="#<!-- TMPL_VAR NAME=patient_id -->"><!-- TMPL_VAR NAME=patient_id --></a></li><!-- /TMPL_LOOP --></ul>
</div>

<h1>Patient Information</h1>
<!-- TMPL_LOOP NAME=patients -->
  <h2 id="<!-- TMPL_VAR NAME=patient_id -->"><!-- TMPL_VAR NAME=patient_id --></h2>
  <ul><!-- TMPL_LOOP NAME=linked_files -->
    <li><a href="http://localhost:60151/load?file=<!-- TMPL_VAR NAME=file_host_dir -->/<!-- TMPL_VAR NAME=patient_id -->/<!-- TMPL_VAR NAME=diskfilename -->"><!-- TMPL_VAR NAME=displayfilename --></a></li><!-- /TMPL_LOOP -->
  </ul>
<!-- /TMPL_LOOP -->
<hr>
<p><small>The end, thank you for reading!</small></p>
</body>
</html>

