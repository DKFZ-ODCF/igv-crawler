time ../igv-crawler.pl --project test-fullpath --report full \
 --groupregex '(te[sz]t)' \
 --display="fullpath" \
 --scandir './data'

time ../igv-crawler.pl --project test-displayregex --report full \
 --groupregex '(te[sz]t)' \
 --display="regex=^.+?/test/data/(.+)" \
 --scandir './data'

time ../igv-crawler.pl --project test-exclude --report full \
 --groupregex '(te[sz]t)' \
 --display="regex=^.+?/test/data/(.+)" \
 --scandir './data' \
 --prunedir 'test-exclude'

