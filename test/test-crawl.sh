time ../igv-crawler.pl --project demo --report full \
 --groupregex 'test/(te[sz]t)' \
 --display="fullpath" \
 --scandir './data'

time ../igv-crawler.pl --project demo --report full \
 --groupregex 'test/(te[sz]t)' \
 --display="regex=^.+?/test/data/(.+)" \
 --scandir './data'

time ../igv-crawler.pl --project demo --report full \
 --groupregex 'test/(te[sz]t)' \
 --display="regex=^.+?/test/data/(.+)" \
 --scandir './data' \
 --prunedir 'test-exclude'

