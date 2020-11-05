# MAPTEMBER YO

# . . . and a bunch of state/province boundaries!
wget -c https://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/cultural/ne_10m_admin_1_states_provinces.zip -O ne_10m_admin_1_states_provinces.zip
unzip ne_10m_admin_1_states_provinces.zip

# Fire up a Postgres DB and enable PostGIS
dropdb maptember_2020 --if-exists
createdb maptember_2020
psql maptember_2020 -c 'CREATE EXTENSION IF NOT EXISTS postgis;CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'

# Move the data to the new DB (to VT state-plane, because *sigh*)
ogr2ogr -where "name_en like 'Vermont%'" -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" ne_10m_admin_1_states_provinces.shp -nln vt_border

######################################################################
# DAY 1: POINTS
######################################################################

# Let's create a layer that explodes the state boundary to points, 
# then perturbs them up to 10km,
# and randomly-sizes them
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day1;
  CREATE TABLE day1 AS (
    WITH points AS (
      SELECT
        d.*
      FROM (
        SELECT
          (ST_DumpPoints(wkb_geometry)).geom AS the_geom_32145
        FROM vt_border
      ) d
    )
    SELECT
      uuid_generate_v4() AS id,
      random() * 5 AS size,
      ST_translate(the_geom_32145,(random() * 10000) - 5000,(random() * 10000) - 5000) AS the_geom_32145
    FROM points
  )
"

######################################################################
# DAY 2: LINES
######################################################################
# Note that I'm living dangerously without indexes b/c this is a small dataset. 
# I bet it'll become necessary later on down the road . . .

# Continuing with the geonoise theme,
# let's join all the day 1 points to their closest neighbor
# (https://gis.stackexchange.com/questions/302290/spatial-join-attributes-based-on-closest-point-in-postgis)
# then make lines to connect them

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day2;
  CREATE TABLE day2 AS (
    SELECT
      uuid_generate_v4() AS id,
      ST_Makeline(a.the_geom_32145,c.the_geom_32145) AS the_geom_32145
    FROM day1 a
    JOIN LATERAL (
      SELECT 
        the_geom_32145
      FROM day1 b
      WHERE a.id != b.id
      ORDER BY a.the_geom_32145 <-> b.the_geom_32145
      LIMIT 1
    ) AS c ON true 

    -- For the hell of it, let's try to sunburst this thing,
    -- with lines radiating out from the state centroid
    UNION ALL

    SELECT
      uuid_generate_v4() AS id,
      ST_Makeline(
        the_geom_32145,
        (
          SELECT
            ST_Centroid(wkb_geometry)
          FROM vt_border
        )
      ) AS the_geom_32145
    FROM day1
  )
"

######################################################################
# DAY 3: POLYGONS
######################################################################

# It's election day! Friggin' vote!
# On this theme I'm going to cast Voronoi polygons around Vermont's 
# polling places (already geocoded, helpfully hosted by our Secretary of State)
wget -c https://www.dropbox.com/s/ucdojode9jc2w37/vt_polling_places_2020.csv?dl=1 -O vt_polling_places_2020.csv

# create shell table
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vt_polling_places_2020;
  CREATE TABLE vt_polling_places_2020 (
    latitude float,
    longitude float,
    town text,
    general_election_polling_place text,
    street_address text,
    polls_open text,
    covid_voting_method text
  );
"

# import data and add geometry
psql maptember_2020 -c "\COPY vt_polling_places_2020 FROM 'vt_polling_places_2020.csv' CSV HEADER;
  SELECT AddGeometryColumn ('public','vt_polling_places_2020','the_geom_32145',32145,'GEOMETRY',2);
  UPDATE vt_polling_places_2020 
  SET the_geom_32145 = ST_Transform(
    ST_GeomFromText(
      'POINT(' || longitude || ' ' || latitude || ')',
      4326
    ),
    32145
  );
"

# build voronois
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day3;
  CREATE TABLE day3 AS (
    WITH v AS (
      SELECT (
        ST_Dump(
          ST_VoronoiPolygons(
            ST_Collect(the_geom_32145),
            100,
            (SELECT wkb_geometry FROM vt_border)
          )
        )
      ).geom AS the_geom_32145
      FROM vt_polling_places_2020
    )
    -- And clip out with the state boundary
    SELECT
      uuid_generate_v4() AS id,
      ST_Intersection(
        the_geom_32145,
        (SELECT ST_Buffer(wkb_geometry,1000) FROM vt_border)
      ) AS the_geom_32145
    FROM v
  )
"

######################################################################
# DAY 4: HEXAGONS
######################################################################

# Everyone's hipster favorite!
# Let's throw a grid over the state of Vermont, then aggregate some interesting values to the cells.

# First order of business - add some appropriate functions, adapted from work provided by the good folks at Carto:
# https://github.com/CartoDB/cartodb-postgresql/blob/362af5e6a0792ce65e8a842cdc1c0dd36d6da6ad/scripts-available/CDB_Hexagon.sql
psql maptember_2020 -f lib/cdb_functions.sql

# Then grab moar basedata - Vermont placenames!
wget -c https://opendata.arcgis.com/datasets/ee1280c35bc7435b890288e50b55a8a8_3.csv?outSR=%7B%22latestWkid%22%3A32145%2C%22wkid%22%3A32145%7D -O vt_placenames.csv

# . . . and import/add geometry
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vt_placenames;
  CREATE TABLE vt_placenames (
    x float,
    y float,
    objectid text,
    gnisid text,
    gname text,
    gntype text,
    cntyname text,
    quadname text,
    townname text,
    cntygeoid int,
    prim_lat_dec float,
    prim_long_dec float,
    elev_in_ft int,
    date_created text,
    date_edited text
  );
"
psql maptember_2020 -c "\COPY vt_placenames FROM 'vt_placenames.csv' CSV HEADER;
  SELECT AddGeometryColumn ('public','vt_placenames','the_geom_32145',32145,'GEOMETRY',2);
  UPDATE vt_placenames 
  SET the_geom_32145 = ST_Transform(
    ST_GeomFromText(
      'POINT(' || prim_long_dec || ' ' || prim_lat_dec || ')',
      4326
    ),
    32145
  );
"

# generate 1.5km hexgrid and assign values to cells
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day4;
  CREATE TABLE day4 AS (
    -- add a grid over the bbox of the state
    WITH grid AS (
      SELECT
        CDB_HexagonGrid(wkb_geometry,1500) AS the_geom_32145
      FROM vt_border
    ),
    -- grab just the cells that overlap the state polygon
    vt_grid AS (
      SELECT
        *
      FROM grid
      WHERE ST_Intersects(
        the_geom_32145,
        (SELECT ST_Buffer(wkb_geometry,1000) FROM vt_border)
      )
    )
    -- aggregate some stats from placename points
    SELECT
      g.the_geom_32145,
      count(p.gnisid) AS count_features,
      -- Set to elevation of the nearest known point where there
      -- are no contained reference points (I know, this is lazy)
      COALESCE(
        avg(p.elev_in_ft),
        (
          SELECT 
            p2.elev_in_ft
          FROM vt_placenames p2
          ORDER BY g.the_geom_32145 <-> p2.the_geom_32145
          LIMIT 1
        )
      ) AS avg_elev
    FROM vt_grid g
    LEFT JOIN vt_placenames p ON ST_Intersects(g.the_geom_32145,p.the_geom_32145)
    GROUP BY g.the_geom_32145
  )
"

######################################################################
# DAY 5: BLUE
######################################################################

# Going fairly simple today. No preprocessing because the feature is
# already imported: the Vermont state border

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day5;
  CREATE TABLE day5 AS (
    SELECT
      * 
    FROM vt_border
  )
"