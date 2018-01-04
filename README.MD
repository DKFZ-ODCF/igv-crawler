# IGV Crawler

This script can crawl filesystems for bioinformatics files that are viewable in the Broad institute's **Integrative Genome Viewer** ([IGV](https://www.broadinstitute.org/software/igv/)).
Found files are grouped by a user-definable regular expression and displayed in a single HTML report. This report uses IGV's 
[HTML remote control capabilities](http://software.broadinstitute.org/software/igv/ControlIGV) and its ability to open files from 
URLs to offer one-click loading of all discovered files.

## Use-cases
I wrote this because at the DKFZ we have a few _peta_bytes worth of genomics data, spread accross hundreds of projects, and 
structured in deeply nested folder hierarchies. Mounting these petabytes on the desktop machines is frowned upon for 
security reasons, and even then, navigating the dozens of folders each time you want to add a track quickly becomes tedious.

This crawler generates an overview (thus saving you from tediousness) and offers the files over URL (thus centralizing the filesystem access to a single, well protected server, instead of dozens of web-surfing, ad-loading, email-attachment-clicking desktops).

Even so, I've written the crawler generic enough that it can search local disks of your laptop as easily as petabyte network mounts, and will also work with URLs to the local filesystem (`file://` urls).


## License and contribution

The script and all related example code is licensed under the MIT license.
Unless specifically stated otherwise, all contributions intentionally submitted by you, to this project will be governed by this same license.

IGV itself is also governed by MIT, so this should impose no extra licensing headaches for you.


## Requirements

### Perl
The crawler script itself is written in strict-mode Perl5 using the following modules:

- Date::Format;
- File::stat;
- File::Find::Rule;
- File::Path;
- File::Spec::Functions;
- Getopt::Long;
- HTML::Template;
- Config::Simple;

### Unix-y filesystem
The crawler generates `symlink`s to only expose IGV-relevant files in the webroot. This means it needs a (unix-y) filesystem with symlink support.

### Webserver
The crawler generates static HTML pages so it requires a webserver. We prefer apache2 for its excellent AD/LDAP-integration, but any static webserver should work, as long as it supports your authentication model and the HTTP [byte-range requests IGV requires](http://software.broadinstitute.org/software/igv/LoadData) for certain file formats.
If you only need an overview of 'local' files on a single machine (including network shares attached to that machine), you can also generate the report with local `File:\\` URLs.


## Design considerations
The crawler is kept deliberately simple. It needs no database, and each crawl will assume nothing about previous states. Each crawl will fully crawl the specified folders.
To keep crawl times manageable, some directives are provided to prune fruitless sub-folders.  
Since crawling can take fairly long (we've seen hours on some bigger project), the crawl will first collect the new state before overwriting the previous report, ensuring that the previous state remains useable during crawling. Only during the few seconds where the symlinks are replaced and the HTML file is rewritten will there be problems the user could notice.


## Security considerations
- If you use this for your local files on your local computer, then basically none.
- If however you are using the server-based setup, beware that you are providing a single point of access (and failure/hacking) into your dataset. Depending on your previous setup, 
  this may be a setback, or an actual improvement.
  - Consider carefully if you want this single server to be internet-facing. For many use-cases, an intranet-only server will suffice. However, it is also a convenient way to share data with collaborators off-site.
  - Also be aware that the crawler and server user will need access to all the data in order to crawl it and serve the file-contents. This will make this user fairly powerfull, and thus risky.
  - To limit the amount of data that is 'visible' to the webserver process, the webroot and dataset do not need to overlap. The crawler will generate symlinks in the webroot that point at
    the dataset, thus ensuring that only relevant data is exposed. Of course, the dataset must still be mounted on the server, so that the symlinks will resolve when the server software accesses them.
    Setting up a single server instance per project, each running under a different user, seems to be too convoluted to be worth the effort.
  - Finally, individual reports can be generated per project/dataset, and each report/subfolder can be protected by its own access control policy in the webservers' config. Make sure that the server access controls match your organisations access controls for the datasets (for example, by tying the webserver configuration to the project access groups in your organisations' AD/LDAP).

# Further questions

If you think anything is unclear, you have more questions, or feel some feature is missing, please open an issue in this repository!
I intend to keep improving this service for the foreseeable future, and "usefullness to others" is a factor I wish to improve, and take into account in my development.
