# IGV Crawler

The IGV crawler gives you an organised view of your bioinformatics project, with one-click visualization of your data in the
Broad institute's **Integrative Genome Viewer** ([IGV](https://www.broadinstitute.org/software/igv/)).

![Screenshot of an IGV crawler report](screenshot-DEEP.png?raw=true "Screenshot of an IGV crawler report")
IGV crawler in action for the DEEP project: linking 2,401 files from 161 donors (after sifting through 17,426 files, so you don't have to!)

The crawler crawls filesystems for bioinformatics files that are viewable in IGV, grouping them by a user-definable regular expression.
The results are displayed in a single HTML report for one-click access by using IGV's
[HTML remote control capabilities](https://software.broadinstitute.org/software/igv/ControlIGV).
Since IGV can open files from URLs, this gives you a sorted overview of your data that is magnitudes easier to navigate than the native file->open dialog.

Its solves the tiniest of UI papercuts, but if I am to believe my enthusiastic colleagues, this makes everyday usage of IGV a million times more pleasant,
especially in large projects (and my colleagues should know: they use it daily to browse over a petabyte of indexed data on the DKFZ server).

## Use-cases
I wrote this because at the DKFZ we have a few _peta_bytes worth of genomics data, spread across hundreds of projects, and
structured in deeply nested folder hierarchies. Mounting these petabytes on the desktop machines is frowned upon for
security reasons, and even then, navigating the dozens of folders each time you want to add a track quickly becomes tedious.

This crawler generates an overview (thus saving you from tediousness) and offers the files over URL (thus centralizing the
filesystem access to a single, well-protected, audited server instead of dozens of web-surfing, ad-loading, email-attachment-clicking desktops).

Even so, I've written the crawler generic enough that it can search local disks of your laptop as easily as petabyte network mounts, and
will also work with URLs to the local filesystem (`file://` URLs).


## License and contribution
This code started as an in-house tool at the German Cancer Research Centre. As this is a publicly funded body,
the code is made open source under the philosophy of ["public money - public code"](https://publiccode.eu/).

The script and all related example code is licensed under the MIT license.
Unless specifically stated otherwise, all contributions intentionally submitted by you, to this project will be governed by this same license.

IGV itself is also governed by MIT, so this should impose no extra licensing headaches for you.


## Requirements

### Perl
The crawler script itself is written in strict-mode Perl5 using the following modules:

- Date::Format;
- DateTime;
- File::stat;
- File::Find::Rule;
- File::Path;
- File::Spec::Functions;
- Getopt::Long;
- HTML::Template;
- Config::Simple;

### Unix-y filesystem
The crawler generates `symlink`s to only expose IGV-relevant files in the report's webroot.
This means it needs a (UNIX-y) filesystem with symlink support.

### Webserver (optional)
The crawler generates static HTML pages so it does not requires a webserver.
You can generate 'local' reports of files available to a single machine (including network shares) by using local `File:\\` URLs.
See the [local siteconfig.ini example](examples/igvcrawler-siteconfig.ini.local-example)

If you do want central hosting, e.g. if your data is too large to fit on a desktop, we recommend apache2.4 (or later)
for its excellent AD/LDAP-integration.
We provide [a server-hosted siteconfig.ini example](examples/igvcrawler-siteconfig.ini.apache-example) and
a [template httpd.conf](examples/apache-httpd.conf.example), based on our own LDAP-based authorisation setup.

However, any static webserver should work, as long as it supports your authentication model and the
[HTTP byte-range requests IGV requires](https://software.broadinstitute.org/software/igv/LoadData) for certain file formats.


## Design considerations
The crawler is kept deliberately simple. It needs no database, and each crawl will assume nothing about previous states.
Each crawl will fully crawl the specified folders. To keep crawl times manageable, some directives are provided to prune fruitless sub-folders.

Since crawling can take fairly long (we've seen hours on some bigger project), the crawl will first collect the new state before overwriting
the previous report, ensuring that the existing state remains usable during crawling.
Only during the few seconds where the symlinks are replaced and the HTML file is rewritten will there be problems the user could notice.


## Security considerations
- If you use this for your local files on your local computer, then basically none.
- If you are using the server-based setup, beware that you are providing a single point of access (and failure/hacking) into your dataset.
  Depending on your previous setup, this may be a setback, or an improvement.
  - Consider carefully if you want this single server to be internet-facing. For many use-cases, an intranet-only server will suffice.
    However, it is also a convenient way to share data with collaborators off-site.
  - Also be aware that the crawler and server user will need access to all the data in order to crawl it and serve the file-contents.
    This will make this user fairly powerful, and thus risky.
  - To limit the amount of data that is 'visible' to the webserver process, the webroot and dataset do not need to overlap.
    The crawler will generate symlinks in the webroot that point at the dataset, thus ensuring that only relevant data is exposed.
    Of course, the dataset must still be mounted on the server, so that the symlinks will resolve when the server software accesses them.
    Setting up a single server instance per project, each running under a different user, seems to be too convoluted to be worth the effort.
  - Finally, individual reports can be generated per project or per dataset, and each report/subfolder can be protected by its own access control policy
    in the webservers' config.
    Make sure that the server access controls match your organisations access controls for the datasets (for example, by tying the webserver configuration
    to the project access groups in your organisations' AD/LDAP, as in our [example httpd.conf](examples/apache-httpd.conf.example)).


# Help improve this project by opening issues!
I intend to keep improving this service for the foreseeable future, and "usefulness to others" is a factor I wish to improve.
Asking questions is a way to help make this project better, so go ahead and [file an issue](issues/new)!
