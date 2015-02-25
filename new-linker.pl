#!/usr/bin/env perl
use strict;
use warnings;
#
# This script scans the specified project folder for
# folders containing <samplename>.bam + <samplename>.bai
# All such bam+bai-files will be linked in the specified output dir
# Additionally it will make a .html index page for users to browse.
#

use File::Find;
use File::Path;
use File::Spec::Functions;
use HTML::Template;


####################################################################################
# SCRIPT GLOBALS
# only used by main funtion, all other references are passed down the call hierarchy.
#
my $project_name = 'DEEP';
# Which directory to scan for bam files
my $input_dir_to_scan = '/icgc/dkfzlsdf/project/DEEP/results/alignments';
# where to create the symlinks to the discovered bamfiles
my $output_link_target_dir = '/public-otp-files/demo/links';
# where $output_link_target_dir is visible for internet access, no trailing slash!
my $output_link_www_dir = 'https://otpfiles.dkfz.de/deep/links';
# where to write the shiny overview page
my $output_index_page = '/public-otp-files/demo/test.html';

# Function to derive a patientID from a filename
# Only thing that should normally be adapted to include a new project
sub derivePatientIdFrom {
  my $filepath = shift;
  $filepath =~ /(\d{2}_[a-zA-Z0-9]+_[a-zA-Z]+)/ ;
  my $patientId = $1;
  return $patientId; 
}

####################################################################################

# global list to keep track of all the bam+bai files we have found
# structure: index => sampleId => list-of-filesystem-paths
my %bambai_file_index = ();

main($project_name, $input_dir_to_scan, $output_link_target_dir, $output_link_www_dir, $output_index_page);


sub main {
  my ($project_name, $dir_to_scan, $output_dir, $output_link_www_dir, $output_index) = @_;
  
  print "Listing bamfiles in $dir_to_scan, making links in $output_dir, writing index file to $output_index\n";

  # finddepth->findFilter stores into global %bambai_file_index, via sub addToIndex()
  finddepth(\&findFilter, $dir_to_scan);

  # map { print "$_ : \n   ", join(",\n   ", @{$bambai_file_index{$_}}), "\n\n" } sort keys %bambai_file_index ;
  makeAllFileSystemLinks($output_dir, %bambai_file_index);

  makeHtmlPage($output_index, $output_link_www_dir, $project_name, %bambai_file_index);
}

sub findFilter {
  my $filename = $File::Find::name;
  return if -d $filename;                     # skip directories
  return unless $filename =~ /(.*)\.ba[im]$/; # skip files that're not a bamfile or a bam-index

  addToIndex($filename);
}

sub addToIndex {
  my $file = shift;

  # extract the patient ID from the identifier
  my $patientId = derivePatientIdFrom($file);
  
  # print "found file for $patientId: $file\n";
  
  # append the file-path to our list of files-per-patient
  $bambai_file_index{$patientId} = [] unless $bambai_file_index{$patientId};
  push @{ $bambai_file_index{$patientId} }, $file;
}

sub makeAllFileSystemLinks {
  my $link_target_dir = shift;
  my %files_per_patientId = @_;

  clearOldLinksIn($link_target_dir);

  foreach my $patientId (keys %files_per_patientId) {
    my $newDir = makeDirectoryFor($link_target_dir, $patientId);
    foreach my $originalFile (@{ $files_per_patientId{$patientId} }) {
      my $filename = getFileNameFor($originalFile);
      my $newPath = catfile($newDir, $filename);
      #print "$originalFile ---> $newPath \n";
      symlink $originalFile, $newPath;
    } 
  }
}

# recursively clears all links from a directory, and then all empty dirs.
# This should normally clear a link-dir made by this script, but nothing else.
sub clearOldLinksIn {
  my $dir_to_clear = shift;
  # sanity, don't let this work on directories that aren't ours
  die "paramaters specify invalid directory to clear: $dir_to_clear" unless $dir_to_clear =~ /^\/public-otp-files\/.*\/links/;

  print "Clearing out links and empty directories in $dir_to_clear\n";
  # delete all symlinks in our directory
  system( "find -P $dir_to_clear -mount -depth -type l  -delete" );
  # clear out all directories that are now empty (or contain only empty directories -> '-p')
  system( "find -P $dir_to_clear -mount -depth -type d  -exec rmdir -p {} + 2> /dev/null" );
}

sub makeDirectoryFor {
  my $link_target_dir = shift;
  my $patientId = shift;

  my $path = catfile($link_target_dir, $patientId);
  mkpath($path) unless -d $path;

  return $path;
}

sub getFileNameFor {
  my $filepath = shift;
  my ($volume, $dir, $filename) = File::Spec->splitpath($filepath);
  return $filename;
}

sub makeHtmlPage {
  my $output_file = shift;
  my $file_host_dir = shift;
  my $project_name = shift;
  my %files_per_patientId = @_;

  # Get the HTML template
  my $html = do { local $/; <DATA> };
  my $template = HTML::Template->new(
   scalarref         => \$html,
#   loop_context_vars => 1,
   global_vars       => 1
  );

  # prepare datstructures to insert into template
  my $timestamp = localtime;
  # sorry for the next unreadable part, explanation:
  # it creates the nested structure for the list-of-patients-with-list-of-their-files 
  # formatted as a (nested) list-of-maps, for HTML::Template
  # [
  #  {
  #    patient_id => "patient_1",
  #    linked_files => [
  #      { filename => "testFile1" },
  #      { filename => "testFile2" },
  #      ...
  #    ]
  #  },
  # ...]
  #
  my $formatted_patients = [
    map {
      {
        patient_id => $_ ,
        linked_files => [
          map {
            { filename => getFileNameFor($_) }
          } @{$bambai_file_index{$_}}
        ]
      }
    } sort keys %bambai_file_index ]; 

#  $html_contents .= addPatientSection($bam_host_dir, %files_per_patientId);
  # insert everything into the template
  $template->param(
    project_name  => $project_name,
    timestamp     => $timestamp,
    file_host_dir => $file_host_dir,
    patients      => $formatted_patients
  );


  writeContentsToFile($template->output(), $output_file);
}

sub addPatientSection {
  my $bam_host_dir = shift;
  my %files_per_patientId = @_;

  my $stringbuffer = '';

  foreach my $patientId (sort keys %files_per_patientId) {
    $stringbuffer .= openListFor($patientId);
    
    my %files_for_current_patientId = map { $_ => 1 } @{ $files_per_patientId{$patientId} };
    foreach my $file (sort %files_for_current_patientId) {
      # If it's a bam-index (bai) file, skip, bai's are checked together with their .bam counterparts in the .bam-half of iterations
      next if $file =~ /\.bai$/;
      
      # skip+log if this bamfile has no accompanying .bai
      # IGV needs a same-named bam-index file in the same location to work properly
      # The index-file contains byte-offsets for base-ranges in the bam, allowing
      # IGV to view ranges without downloading the entire (multi-gig) .bam
      my $expected_bai = $file;
      $expected_bai =~ s/\.bam$/\.bai/;
      if (exists($files_for_current_patientId{$expected_bai})) {
        $stringbuffer .= makeIgvBamLinkFor($file, $bam_host_dir, $patientId);
      }
    }

    $stringbuffer .= closeList();
  }
  return $stringbuffer;
}

sub openListFor {
  my $patientId = shift;

  return "
    <h2>$patientId</h2>
      <ul>";
}

sub closeList {
  return "
      </ul>
    ";
}

sub makeIgvBamLinkFor {
  my $bamfile = shift;
  my $bam_host_dir = shift;
  my $patientId = shift;
  my $filename = getFileNameFor($bamfile);
  
  return "
        <li><a href=\"http://localhost:60151/load?file=$bam_host_dir/$patientId/$filename&genome=1kg_v37\">$filename</a></li>";
}

sub writeContentsToFile {
  my $contents = shift;
  my $filename = shift;

  #print "writing stuff to $filename\n";
  open (FILE, "> $filename") || die "problem opening $filename\n";
  print FILE $contents;
  close (FILE);
  #print $contents;
}

__DATA__
<html>
<head>
  <title>IGV files for <!-- TMPL_VAR NAME=project_name --></title>
</head>

<body>
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
<li>the reference genome is available (genomes > load genome from server > add "Human&nbsp;(1kg&nbsp;b37&nbsp;+&nbsp;decoy)", also known as "1kg_v37"<br/>
(do this before loading files, or all positions will show up as mutated)<br/>
This is only needed once, after IGV learns about this reference-genome, it will recognise it automatically in the links below.</li>
</ol>
</p>
<small><p>last updated: <!-- TMPL_VAR NAME=timestamp -->, a service by the eilslabs data management group</p></small>

<h1>Patient Information</h1>
<!-- TMPL_LOOP NAME=patients -->
  <h2><!-- TMPL_VAR NAME=patient_id --></h2>
  <ul>
    <!-- TMPL_LOOP NAME=linked_files -->
      <li>
        <a href="http://localhost:60151/load?file=<!-- TMPL_VAR NAME=file_host_dir -->/<!-- TMPL_VAR NAME=patient_id -->/<!-- TMPL_VAR NAME=filename -->&genome=1kg_v37">
          <!-- TMPL_VAR NAME=filename -->
        </a>
      </li>
    <!-- /TMPL_LOOP -->
  </ul>
<!-- /TMPL_LOOP -->

</body>
</html>

