#!/bin/bash

UNIXTIME=`date +%s%N`
HOSTNAME=`hostname -a`
DBPORT=<change it>
DQ='\"'
DBUSER=telegraf
DBHOST=localhost
OUTPUT_FOLDER=/etc/telegraf/DONT_DELETE
TABLESIZE_OUTPUT=$OUTPUT_FOLDER/table_size.csv
TABLESTATISTICS_OUTPUT=$OUTPUT_FOLDER/table_statistics.csv
BLOATS_OUTPUT=$OUTPUT_FOLDER/bloats.csv

> $TABLESIZE_OUTPUT
> $TABLESTATISTICS_OUTPUT
> $BLOATS_OUTPUT

chown postgres:postgres $TABLESIZE_OUTPUT
chown postgres:postgres $TABLESTATISTICS_OUTPUT
chown postgres:postgres $BLOATS_OUTPUT

for DB in $(su - postgres -c "psql -h $DBHOST -p $DBPORT -qAt -U $DBUSER -d postgres -c \" select datname from pg_database where datname not in ('template0','template1')\""); do

  echo $(su - postgres -c "psql -h $DBHOST -p $DBPORT -qAt -U $DBUSER -d $DB -c \"
  WITH constants AS (
  SELECT current_setting('block_size')::numeric AS bs, 23 AS hdr, 4 AS ma),
bloat_info AS (
  SELECT
    ma,bs,schemaname,tablename,
    (datawidth+(hdr+ma-(case when hdr%ma=0 THEN ma ELSE hdr%ma END)))::numeric AS datahdr,
    (maxfracsum*(nullhdr+ma-(case when nullhdr%ma=0 THEN ma ELSE nullhdr%ma END))) AS nullhdr2
  FROM (
    SELECT
      schemaname, tablename, hdr, ma, bs,
      SUM((1-null_frac)*avg_width) AS datawidth,
      MAX(null_frac) AS maxfracsum,
      hdr+(
        SELECT 1+count(*)/8
        FROM pg_stats s2
        WHERE null_frac<>0 AND s2.schemaname = s.schemaname AND s2.tablename = s.tablename
      ) AS nullhdr
    FROM pg_stats s, constants
    GROUP BY 1,2,3,4,5
  ) AS foo
)
, table_bloat AS (
  SELECT
    schemaname, tablename, cc.relpages, bs,
    CEIL((cc.reltuples*((datahdr+ma-(CASE WHEN datahdr%ma=0 THEN ma ELSE datahdr%ma END))+nullhdr2+4))/(bs-20::float)) AS otta,
        pg_relation_size(cc.oid) as object_size
  FROM bloat_info
  JOIN pg_class cc ON cc.relname = bloat_info.tablename
  JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname = bloat_info.schemaname AND nn.nspname not in ('information_schema','pg_catalog')
)
, index_bloat AS (
  SELECT
    schemaname, tablename, bs,
    COALESCE(c2.relname,'?') AS iname, COALESCE(c2.reltuples,0) AS ituples, COALESCE(c2.relpages,0) AS ipages,
    COALESCE(CEIL((c2.reltuples*(datahdr-12))/(bs-20::float)),0) AS iotta, -- very rough approximation, assumes all cols,
        pg_indexes_size(cc.oid) as object_size
  FROM bloat_info
  JOIN pg_class cc ON cc.relname = bloat_info.tablename
  JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname = bloat_info.schemaname AND nn.nspname not in ('information_schema','pg_catalog')
  JOIN pg_index i ON indrelid = cc.oid
  JOIN pg_class c2 ON c2.oid = i.indexrelid
)
SELECT  'postgresql.bloats' || ',' || '$DB' || ',' || '$HOSTNAME' || ',' || '$HOSTNAME' || ',' || type || ',' || schemaname || ',' || object_name || ',' || bloat || ',' || (raw_waste) || ',' || object_size || ',' || '$UNIXTIME'
FROM
(SELECT
  'table' as type,
  schemaname,
  tablename as object_name,
  ROUND(CASE WHEN otta=0 THEN 0.0 ELSE table_bloat.relpages/otta::numeric END,1) AS bloat,
  CASE WHEN relpages < otta THEN '0' ELSE (bs*(table_bloat.relpages-otta)::bigint)::bigint END AS raw_waste,
  object_size
FROM
  table_bloat
    UNION
SELECT
  'index' as type,
  schemaname,
  iname as object_name,
  ROUND(CASE WHEN iotta=0 OR ipages=0 THEN 0.0 ELSE ipages/iotta::numeric END,1) AS bloat,
  CASE WHEN ipages < iotta THEN '0' ELSE (bs*(ipages-iotta))::bigint END AS raw_waste,
  object_size
FROM
  index_bloat) bloat_summary
ORDER BY raw_waste DESC, bloat DESC
limit 20  \" >> $BLOATS_OUTPUT")

done
