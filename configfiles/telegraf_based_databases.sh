#!/bin/bash

UNIXTIME=`date +%s%N`
HOSTNAME=`hostname -a`
DQ='\"'
DBUSER=telegraf
DBHOST=localhost
DBPORT=<change it>

OUTPUT_FOLDER=/etc/telegraf/DO_NOT_DELETE
BLOATS_OUTPUT=$OUTPUT_FOLDER/bloats.csv
DBSERVERINFO_OUTPUT=$OUTPUT_FOLDER/dbServerInfo.csv
ALLTABLESTATISTICS_OUTPUT=$OUTPUT_FOLDER/allTablesStatistics.csv
VACUUMPROGRESS_OUTPUT=$OUTPUT_FOLDER/vacuumProgress.csv

> $BLOATS_OUTPUT
> $DBSERVERINFO_OUTPUT
> $ALLTABLESTATISTICS_OUTPUT
> $VACUUMPROGRESS_OUTPUT

chown postgres:postgres $BLOATS_OUTPUT
chown postgres:postgres $DBSERVERINFO_OUTPUT
chown postgres:postgres $ALLTABLESTATISTICS_OUTPUT
chown postgres:postgres $VACUUMPROGRESS_OUTPUT

for DB in $(su - postgres -c "psql -h $DBHOST -p $DBPORT -qAt -U $DBUSER -d $DB -c \" select datname from pg_database where datname not in ('template0','template1')\""); do

  # Collect All Table Statistics
  echo $(su - postgres -c "psql -h $DBHOST -p $DBPORT -qAt -U $DBUSER -d $DB -c \" SELECT 'postgresql.all_table_statistics' || ',' || '$DB' || ',' || '$HOSTNAME' || ',' || '$HOSTNAME' || ',' || schemaname || ',' || relname || ',' || pg_total_relation_size(relid) || ',' || pg_total_relation_size(relid) - pg_relation_size(relid) || ',' ||  seq_scan|| ',' || seq_tup_read|| ',' || coalesce(idx_scan,0)|| ',' || coalesce(idx_tup_fetch,0) || ',' || coalesce(n_tup_ins,0)|| ',' || coalesce(n_tup_upd,0) || ',' || coalesce(n_tup_del,0) || ',' || coalesce(n_tup_hot_upd,0) || ',' || coalesce(n_live_tup,0) || ',' || coalesce(n_dead_tup,0) || ',' || coalesce(n_mod_since_analyze,0) || ',' || coalesce(last_vacuum,'2020-01-01') || ',' || coalesce(last_autovacuum,'2020-01-01') || ',' || coalesce(last_analyze,'2020-01-01') || ',' || coalesce(last_autoanalyze,'2020-01-01')|| ',' || coalesce(vacuum_count,0)|| ',' || coalesce(autovacuum_count,0)|| ',' || coalesce(analyze_count,0)|| ',' || coalesce(autoanalyze_count,0) || ',' || $UNIXTIME  FROM pg_catalog.pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC\" >> $ALLTABLESTATISTICS_OUTPUT")

  # Collect Vacuum Progress Information
echo $(su - postgres -c "psql -h $DBHOST -p $DBPORT -qAt -U $DBUSER -d $DB -c \" select 'postgresql.pg_stat_progress_vacuum' || ',' || extract(EPOCH FROM now()-query_start::timestamp)::int || ',' ||  heap_blks_total-heap_blks_scanned || ',' || c.relname || ',' || (100*heap_blks_scanned)/heap_blks_total || ',' || (100*spv.heap_blks_vacuumed)/heap_blks_total  || ',' || spv.pid || ',' ||  spv.phase || ',' ||  spv.heap_blks_total || ',' ||  spv.heap_blks_scanned || ',' ||  spv.heap_blks_vacuumed || ',' ||  spv.index_vacuum_count || ',' ||  spv.max_dead_tuples || ',' ||  spv.num_dead_tuples || ',' ||  $UNIXTIME from pg_stat_progress_vacuum spv inner join pg_class c on c.oid=spv.relid inner join pg_stat_activity sa on sa.pid=spv.pid and sa.state='active'\" >> $VACUUMPROGRESS_OUTPUT")

  # Collect Bloat Information
  echo $(su - postgres -c "psql -h $DBHOST -p $DBPORT -qAt -U $DBUSER -d $DB -c \" WITH constants AS (
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
SELECT  'postgresql.bloats' || ',' || '$DB' || ',' || '$HOSTNAME' || ',' || '$HOSTNAME' || ',' || type || ',' || schemaname || ',' || object_name || ',' || bloat::float || ',' || (raw_waste) || ',' || object_size::float || ',' || '$UNIXTIME'
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
limit 20 \" >> $BLOATS_OUTPUT")

done

# Collect General Information About Server And Db
echo dbserverinfo,$(hostname -a),$(hostname -a),$(hostname -i),$(su - postgres -c "/usr/pgsql-11/bin/pg_isready -p $DBPORT"),$(su - postgres -c "psql -p $DBPORT -qAt -c \"select (substring(version() from position(' ' in version())+1 for (position('on' in version())-position(' ' in version())-4)))::int"\"),$(df -a /data | awk '{print $2 "," $3 "," 100*$3/$2}'| tail -n -1),$(su - postgres -c "psql -p1923 -qAt -c \"select case when (exists (select * from pg_hba_file_rules hfr where hfr.database = '{replication}' and address != '127.0.0.1' and address != '::1') and (select pg_is_in_recovery()) is false) then 'primary db server' when (select pg_is_in_recovery()) then 'secondary db server' end\""),$UNIXTIME >> $DBSERVERINFO_OUTPUT

