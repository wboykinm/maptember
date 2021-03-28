# MAPTEMBER YO

# . . . grab a bunch of state/province boundaries to start!
wget -c https://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/cultural/ne_10m_admin_1_states_provinces.zip -O ne_10m_admin_1_states_provinces.zip
unzip ne_10m_admin_1_states_provinces.zip

# Fire up a Postgres DB and enable PostGIS
dropdb maptember_2020 --if-exists
createdb maptember_2020
psql maptember_2020 -c 'CREATE EXTENSION IF NOT EXISTS postgis;CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'

# Move the data to the new DB (to VT state-plane, because *sigh*)
ogr2ogr -where "name_en like 'Vermont%'" -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" ne_10m_admin_1_states_provinces.shp -nln vt_border

# As will be my custom, maps will be rendered w/ QGIS, using the excellent 
# [PostGIS connector](https://docs.qgis.org/3.16/en/docs/training_manual/databases/db_manager.html#basic-fa-managing-postgis-databases-with-db-manager) 
# to keep a fresh connection with the data I'm crunching,  and to abstract
# away the basemap-building. The QGIS project file is [here](projects/maptember_2020.qgz)

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

######################################################################
# DAY 6: RED
######################################################################

# Against my better judgement, I'm going to show the vote differential in the
# VT Governor's election, with data mercifully provided by local outlet extraordinaire
# VTDigger: https://vtdigger.org/2020/11/04/how-vermonters-voted-in-tuesdays-top-races-town-by-town/
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vt_gov_2020;
  CREATE TABLE vt_gov_2020 (
    town text,
    emily_peyton int,
    erynn_hazlett_whitney int,
    david_zuckerman int,
    michael_a_devost int,
    phil_scott int,
    kevin_hoyt int,
    wayne_billado_iii int,
    charly_dickerson int,
    john_klar int,
    spoiled_votes int,
    blank_votes int,
    total_write_ins int,
    total_votes int,
    winner text,
    winner_percent float
  );
"
psql maptember_2020 -c "\COPY vt_gov_2020 FROM 'data/election/data-WkZ49.csv' CSV HEADER;"

# . . . and presidential results:
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vt_prez_2020;
  CREATE TABLE vt_prez_2020 (
    town text,
    sum_of_roque_rocky_de_la_fuente_and_darcy_g_richardson int,
    sum_of_brian_carroll_and_amar_patel int,
    sum_of_blake_huber_and_frank_atwood int,
    sum_of_jerome_segal_and_john_de_graaf int,
    sum_of_keith_mccormic_and_sam_blasiak int,
    sum_of_christopher_lafontaine_and_michael_speed int,
    sum_of_don_blankenship_and_bill_mohr int,
    sum_of_howie_hawkins_and_angela_walker int,
    sum_of_h_brooke_paige_and_thomas_james_witman int,
    sum_of_kanye_west_and_michelle_tidball int,
    sum_of_kyle_kenley_kopitke_and_taja_yvonne_iwanow int,
    sum_of_jo_jorgensen_and_jeremy_spike_cohen int,
    sum_of_gloria_lariva_and_sunil_freeman int,
    sum_of_phil_collins_and_billy_joe_parker int,
    sum_of_richard_duncan_and_mitch_bupp int,
    zachary_scalf_and_matthew_lyda int,
    alyson_kennedy_and_malcolm_jarrett int,
    brock_pierce_and_karla_ballard int,
    donald_j_trump_and_michael_r_pence int,
    joseph_r_biden_and_kamala_d_harris int,
    spoiled_votes int,
    blank_votes int,
    total_writeins int,
    total_votes int,
    winner text,
    winner_percent text
  );
"
psql maptember_2020 -c "\COPY vt_prez_2020 FROM 'data/election/data-ezDzH.csv' CSV HEADER;"

# Also, get town boundaries from the wonderful VCGI:
wget -c https://opendata.arcgis.com/datasets/0e4a5d2d58ac40bf87cd8aa950138ae8_39.zip?outSR=%7B%22latestWkid%22%3A32145%2C%22wkid%22%3A32145%7D -O vt_towns.zip
unzip vt_towns.zip
ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" "VT_Data_-_Town_Boundaries.shp" -nlt MULTIPOLYGON -nln vt_towns

# Let's crunch it all together!
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day6;
  CREATE TABLE day6 AS (
    SELECT
      t.townname,
      t.wkb_geometry AS the_geom_32145,
      ST_Centroid(t.wkb_geometry) AS the_geom_point_32145,
      max(g.total_votes) AS gov_total_votes,
      max(g.winner) AS gov_winner,
      max(g.winner_percent) AS gov_winner_percent,
      max(p.total_votes) AS prez_total_votes,
      max(p.winner) AS prez_winner,
      max(p.winner_percent) AS prez_winner_percent,
      max(g.phil_scott) - max(p.donald_j_trump_and_michael_r_pence) AS gov_outperformance
    FROM vt_towns t
    LEFT JOIN vt_gov_2020 g ON g.town = t.townname
    LEFT JOIN vt_prez_2020 p ON p.town = t.townname
    GROUP BY t.townname,t.wkb_geometry
  );
"

######################################################################
# DAY 7: GREEN
######################################################################

# Returning to placenames for this one, let's look at occurrences of the word "green" in VT
# Can't imagine there are too many . . .

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day7;
  CREATE TABLE day7 AS (
    SELECT
      *
    FROM vt_placenames
    WHERE gname ILIKE '%green%'
  )
"

######################################################################
# DAY 8: YELLOW
######################################################################

# Now trying "yellow"

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day8;
  CREATE TABLE day8 AS (
    SELECT
      *
    FROM vt_placenames
    WHERE gname ILIKE '%yellow%'
  )
"

######################################################################
# DAY 9: MONOCHROME
######################################################################

# This is going to be a bit of a cheat, since my basemap here has been 
# b&w from the jump. But to make it interesting I'm going to add contours!
wget -c https://opendata.arcgis.com/datasets/4e119b631fd2492c86bf81b060b9ccb0_3.zip?outSR=%7B%22wkid%22%3A32145%2C%22latestWkid%22%3A32145%7D -O vt_contours_50.zip
unzip vt_contours_50.zip
ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" "VT_50_foot_contours_generated_from_USGS_30_meter_NED_DEM.shp" -nln vt_contours_50

# There are 60k+ contour features. Let's cut 'em (read: "clip") to the border we're using.
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day9;
  CREATE TABLE day9 AS (
    SELECT
      c.contour,
      ST_Intersection(
        c.wkb_geometry,
        b.wkb_geometry
      ) AS the_geom_32145
    FROM vt_contours_50 c, vt_border b
  )
"

# Remember that 10% of mapmaking that ISN'T data processing? yeah, that's
# been happening in QGIS. In this case, using a gradient based on the
# Financial Times' background color (which I LOVE):
# ['#000000','#552700','#aa4e00','#ff7500','#fea355','#ffd1a9','#ffffff]

######################################################################
# DAY 10: GRID
######################################################################

# But we already used hexagooooooooons! Okay, let's go squares.

# Add a grid-generating function from teh internetz
psql maptember_2020 -f lib/general_functions.sql

# Lets also get wild by bringing in Microsoft's building set for the state
wget -c https://usbuildingdata.blob.core.windows.net/usbuildings-v1-1/Vermont.zip -O Vermont.zip
unzip Vermont.zip
ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" Vermont.geojson -nlt MULTIPOLYGON -nln vt_buildings

# Set a few constants:
SIDE=2000
MAX_COUNT=200

# Build the grid record over the state
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day10;
  CREATE TABLE day10 AS (
    WITH grid AS (
      SELECT 
        ST_Transform(the_geom,32145) AS the_geom_32145
      FROM (
        SELECT (
          -- This bit forms a grid over the VT bbox
          ST_Dump(
            makegrid_2d(
              (SELECT ST_Envelope(ST_Transform(wkb_geometry,4326)) FROM vt_border),
              ${SIDE},
              ${SIDE}
            )
          )
      ).geom AS the_geom) AS grid
      -- . . . and then grab just the cells that overlap the state proper
      WHERE ST_Intersects(
        the_geom,
        (SELECT ST_Transform(wkb_geometry,4326) FROM vt_border)
      )
    ),
    building_stats AS (
      -- join sampled MS building counts to the cells
      SELECT
        g.the_geom_32145,
        count(b.*) AS buildings
      FROM grid g
      LEFT JOIN (
        SELECT *
        FROM vt_buildings 
        WHERE random() < 0.1
      ) b ON ST_Intersects(g.the_geom_32145,b.wkb_geometry)
      GROUP BY g.the_geom_32145
    )
    -- Then adjust cell size by building count
    SELECT
      buildings,
      buildings / ${MAX_COUNT}::float AS ratio,
      -- Wild stuff required here: https://gis.stackexchange.com/a/29893/10198
      ST_Translate(
        -- Scale down the features!
        ST_Scale(the_geom_32145,buildings / ${MAX_COUNT}::float,buildings / ${MAX_COUNT}::float),
        -- Then move them back where they came from!
        ST_X(ST_Centroid(the_geom_32145))*(1 - (buildings / ${MAX_COUNT}::float)),
        ST_Y(ST_Centroid(the_geom_32145))*(1 - (buildings / ${MAX_COUNT}::float))
      ) AS the_geom_32145 
    FROM building_stats
  )
"

######################################################################
# DAY 11: 3D
######################################################################

# Off the deep end! While only-vaguely 3d, this time we'll follow the ever-popular
# https://somethingaboutmaps.wordpress.com/2017/11/16/creating-shaded-relief-in-blender/

# Set VT SRTM tiles, then grab and unzip them (only works with auth, unfortunately)
VT_SRTM=( 'N45W074' 'N45W073' 'N45W072' 'N44W074' 'N44W073' 'N44W072' 'N43W073' 'N43W074' 'N42W073' 'N42W074' )
for t in "${VT_SRTM[@]}"; do
  # for manual download (eyeroll)
  echo "http://e4ftl01.cr.usgs.gov/MEASURES/SRTMGL1.003/2000.02.11/${t}.SRTMGL1.hgt.zip"
  # wget -c http://e4ftl01.cr.usgs.gov/MEASURES/SRTMGL1.003/2000.02.11/${t}.SRTMGL1.hgt.zip -O ${t}.zip
  # unzip ${t}.zip
done

# Combine the SRTM tiles and convert to .tif
gdal_merge.py -o data/srtm_30m/srtm_30m_vt.tif data/srtm_30m/N4*.hgt

# Pull out geojson of the state border and clip the raster with it
psql maptember_2020 -t -c "
  SELECT 
    ST_AsGeoJSON(
      ST_Transform(wkb_geometry,4326)
    ) 
  FROM vt_border
" > vt_border.geojson
gdalwarp -t_srs "EPSG:32145" -ot UInt16 -cutline vt_border.geojson data/srtm_30m/srtm_30m_vt.tif data/srtm_30m/srtm_30m_vt_clipped.tif
gdal_translate -scale 0 1201 0 65535 data/srtm_30m/srtm_30m_vt_clipped.tif data/srtm_30m/srtm_30m_vt_scaled.tif

# Head on over to blender and follow the instructions at the link above. Mayhem ensues!
# Specificaly, rendering the 3d version of this DEM to a full-size .png in blender will
# crash your machine! Render it to 50% scale instead, and then . . .

# Embiggen to the original dimensions
convert data/srtm_30m/srtm_30m_vt_relief_half.tif -adaptive-resize 8854x15871 data/srtm_30m/srtm_30m_vt_relief.tif

# Get the worldfile from the original
gdal_translate -co "TFW=YES" data/srtm_30m/srtm_30m_vt_scaled.tif data/srtm_30m/srtm_30m_vt_tfw.tif

# Apply it to the blender output (and cross fingers)
cp data/srtm_30m/srtm_30m_vt_tfw.tfw data/srtm_30m/srtm_30m_vt_relief.tfw
gdal_translate -a_srs "EPSG:32145" -of GTiff data/srtm_30m/srtm_30m_vt_relief.tif data/srtm_30m/srtm_30m_vt_relief_geo.tif

######################################################################
# DAY 12: MAP NOT MADE WITH GIS SOFTWARE
######################################################################

# What with the rise of geospatial data science, there are lots of options here, but
# what the hell - let's use paint. First let's make something traceable.
# Using this high-contrast d3js thing: http://bl.ocks.org/wboykinm/c450c20af3519a07c8ea405acd2a3292
# . . . but locally, stashed here in lib/, so fire up an http server:

static-server -p 8000

# Then visit http://localhost:8000/lib/day12.html, ctrl-j to bring up the js console, then enter
# document.body.setAttribute( "style", "-webkit-transform: rotate(-90deg);");
# . . . to better fit the state to the screen

# Literally tape a sheet of printer paper to the screen, crank up the brightness,
# and trace the feature outlines lightly on. Then remove from the laptop,
# bust out the watercolors, and fill in those polygons that are just begging
# for some saturation. Scan back in when done. 

# NO GIS-ES WERE INJURED IN THE MAKING OF THIS MAP.


######################################################################
# DAY 13: RASTER
######################################################################

# Working from Paul Ramsey's PostGIS raster demo:
# https://info.crunchydata.com/blog/waiting-for-postgis-3-separate-raster-extension

# Load the srtm dataset we prepared above into the DB:
raster2pgsql -I -F -s 32145 -t 500x800 data/srtm_30m/srtm_30m_vt_clipped.tif srtm_30m_vt_clipped | psql maptember_2020

# And . . . that's it! Render in QGIS over Mapbox Satellite tiles with "overlay"
# blending set, and it neatly combines the two. But more importantly, YOU'VE 
# LOADED A RASTER DATASET INTO POSTGIS. Celebrate accordingly.

######################################################################
# DAY 14: CLIMATE CHANGE
######################################################################

# In many ways, Vermont's wake-up moment to the effects of climate change
# was in 2011, when hurricane Irene made landfall in NJ but then kept rolling north
# Into the Green Mountains, doing flood damage the state hadn't seen in
# nearly a century. Taking a look at the high-water marks from that storm
# is a good way to realize that sea level rise isn't the only water-related
# threat, and that even landlocked, mountainous regions are at risk.

# Let's get the high water marks from USGS and bring them in:
wget -c https://pubs.usgs.gov/ds/763/appendixes_final/ds763_appendix3.kmz
unzip ds763_appendix3.kmz
ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" doc.kml -nln vt_irene_hwm

# Now let's get elevations for those points from our existing SRTM raster
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day14;
  CREATE TABLE day14 AS (
    SELECT
      i.*,
      ST_Value(s.rast,i.wkb_geometry) AS elevation
    FROM vt_irene_hwm i
    JOIN srtm_30m_vt_clipped s ON ST_Intersects(i.wkb_geometry,s.rast)
  )
"
# Using SQL on raster is a liiiiiiiitle tough to wrap my head around, but the
# implementation is simple enough for this sort of thing.

######################################################################
# DAY 15: CONNECTIONS
######################################################################

# A hockey tournament in New Hampshire at the beginning of October 
# has been identified by health officials as the source of the Vermont's 
# largest and most-widespread outbreak since the pandemic began.
# Data provided by the DOH and VTDigger show how the participants
# carried the virus around the state, sparking additional outbreaks.

# Get data: https://vtdigger.org/2020/11/13/where-is-the-latest-wave-vermonts-recent-covid-cases-town-by-town/

# MASSIVE CAVEATS
# THESE ARE NOT THE LOCATIONS OF INDIVIDUALS
# I AM NOT AN EPIDEMIOLOGICAL GEOGRAPHER
# THIS IS AN INFERRED NETWORK - THERE IS NO AGENCY CONFIRMATION THAT 
# THE SAME EVENT CAUSED ALL OF THESE INFECTIONS

# Ingest
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vtdigger_stats_20201113;
  CREATE TABLE vtdigger_stats_20201113 (
    town text,
    culmulative_cases_1111 int,
    culmulative_cases_1021 int,
    change_since_oct_21 text
  )
"
psql maptember_2020 -c "\COPY vtdigger_stats_20201113 FROM 'data/covid/vtdigger_stats_20201113.csv' CSV HEADER" 

# Combine with town location and infer network
MAX_DIST=7000
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day15a;
  CREATE TABLE day15a AS (
    -- Create the baseline table, with centroids by town
    WITH baseline AS (
      SELECT
        s.town,
        culmulative_cases_1111 - culmulative_cases_1021 AS case_increase,
        ST_Centroid(t.wkb_geometry) AS the_geom_32145
      FROM vtdigger_stats_20201113 s
      JOIN vt_towns t ON t.townname = upper(s.town)
    ),
    -- Separate source and target
    source AS (
      SELECT
        town,
        'source'::text AS stage,
        'none'::text AS parent,
        the_geom_32145
      FROM baseline 
      WHERE town = 'Montpelier'
    ),
    spread AS (
      SELECT
        town,
        'spread'::text AS stage,
        'Montpelier'::text AS parent,
        the_geom_32145 
      FROM baseline 
      WHERE town != 'Montpelier' AND case_increase > 3
    ),
    -- Add random points for each case at each target
    target AS (
      SELECT
        town, 
        'target'::text AS stage,
        town::text AS parent,
        -- Randomize geometry out to 5km
        ST_Translate(the_geom_32145,(-${MAX_DIST}+(${MAX_DIST}*2)*random()),(-${MAX_DIST}+(${MAX_DIST}*2)*random())) AS the_geom_32145
      FROM 
        baseline,
        generate_series(1,case_increase)
      WHERE baseline.case_increase > 3
    )
    SELECT * FROM source
    UNION ALL
    SELECT * FROM spread
    UNION ALL
    SELECT * FROM target
  )
"

# Make a second geometry, adding lines connecting dest to source
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day15b;
  CREATE TABLE day15b AS (
    SELECT
      d1.stage || '_' || d2.stage AS type,
      ST_Makeline(d1.the_geom_32145,d2.the_geom_32145) AS the_geom_32145
    FROM day15a d1
    JOIN day15a d2 ON d1.town = d2.parent
    WHERE d1.stage IN ('source','spread')
    AND d2.stage IN ('spread','target')
  )
"

######################################################################
# DAY 16: ISLAND(S)
######################################################################

# On a happier note, let's go back to the geologically-recent past 
# and spend some time elevation-generating the Champlain sea: 
# https://en.wikipedia.org/wiki/Champlain_Sea

# We'll use the already-imported
# SRTM data and continue looking at Paul Ramsey's PostGIS raster methods
# https://info.crunchydata.com/blog/waiting-for-postgis-3-separate-raster-extension

# Make polygons based on the elevation at the extent of the sea at water 
# height maximum (~183m)
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day16a;
  CREATE TABLE day16a AS (
    WITH overview AS (
      SELECT (
        ST_DumpAsPolygons(
          ST_Reclass(
            ST_Union(rast),
            '-1000-183:1-1, 183-5000:0-0',
            '2BUI'
          )
        )
      ).*
      FROM srtm_30m_vt_clipped s
    )
    SELECT
      ST_Intersection(
        geom,
        (SELECT wkb_geometry FROM vt_border)
      ) AS the_geom_32145,
      (CASE WHEN val = 0 THEN 'land' ELSE 'water' END) As type
    FROM overview
  )
"

# Then buffer out the islands based on a VERY basic heuristic 
# (everything smaller than 500MM sqm)
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day16b;
  CREATE TABLE day16b AS (
    SELECT 
      ST_Union(ST_Buffer(the_geom_32145,1000)) AS the_geom_32145
    FROM day16a
    WHERE type = 'land'
    AND ST_Area(the_geom_32145) < 500000000
  )
"

# This is an elevation processing experiment. For ACTUAL Champlain sea extents,
# see Van Hoesen et al., 2020: 
# https://geodata.vermont.gov/datasets/VTANR::glacial-lakes-and-the-champlain-sea

######################################################################
# DAY 17: HISTORICAL
######################################################################

# Bypassing PostGIS for this one, instead we'll use mapwarper to "rectify" (LOL)
# Samuel de Champlain's 1612 "Carte Geographique de la Nouvelle France", housed helpfully
# in wikimedia commons: https://commons.wikimedia.org/wiki/File:Samuel_de_Champlain_Carte_geographique_de_la_Nouvelle_France.jpg

# Upload to mapwarper: https://mapwarper.net/maps/51751

# Really only the barest minimum of georeferencing is possible given the fact that
# the modern concept of longitude didn't really exist yet in 1612, and the gentleman 
# in question traveled Vermont solely by canoe. This is more of an art piece :)

# Use built-in XYZ endpoint in QGIS: https://mapwarper.net/maps/tile/51751/{z}/{x}/{y}.png

######################################################################
# DAY 18: LAND USE
######################################################################

# Get NLCD 2016 extract (will expire)
mkdir tmp/
cd tmp
wget -c https://www.mrlc.gov/downloads/sciweb1/shared/mrlc/download-tool/NLCD_avAESMFIdgkNMxXtxKoH.zip
unzip NLCD_avAESMFIdgkNMxXtxKoH.zip

# As above, pull out geojson of the state border and clip the raster with it
psql maptember_2020 -t -c "
  SELECT 
    ST_AsGeoJSON(
      ST_Transform(wkb_geometry,4326)
    ) 
  FROM vt_border
" > vt_border.geojson

# convert to wgs84, clip to state bound
gdalwarp -t_srs "EPSG:4326" NLCD_2016_Tree_Canopy_L48_20190831_avAESMFIdgkNMxXtxKoH.tiff NLCD_2016_Tree_Canopy_4326.tif

# Cut out the state boundary
gdalwarp -dstnodata 0 -cutline vt_border.geojson NLCD_2016_Tree_Canopy_4326.tif NLCD_2016_Tree_Canopy_clipped.tif

# Send to DB
raster2pgsql -I -F -s 4326 NLCD_2016_Tree_Canopy_clipped.tif nlcd_2016_tree_canopy_clipped | psql maptember_2020

# And render over the blender-derived shaded relief from day 11!
# Shouts to Sarah Bell for the font I'm now using predominantly:
# https://www.sarahbellmaps.com/typography-for-topography-belltopo-sans-free-font/

# Oh, and cleanup. This was a LOT of NLCD data.
cd ../
rm -r tmp/

######################################################################
# DAY 19: NULL
######################################################################

# If you try to navigate to "Vermont" from anywhere using Google maps, you'll be 
# directed to the side yard of a nondescript house in Morrisville.

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day19;
  CREATE TABLE day19 AS (
    SELECT
      'Nullyard'::text AS name,
      ST_Transform(
        ST_GeomFromText('POINT(-72.577846 44.558801)', 4326),
        32145
      ) AS the_geom_32145
  )
"

# While NULL locations have a long and storied history, they usually
# have a pretty good [if stupid] explanation: 
# (https://www.theguardian.com/technology/2016/aug/09/maxmind-mapping-lawsuit-kansas-farm-ip-address) 
# But despite a local newpaper piece:
# (https://www.sevendaysvt.com/vermont/wtf-why-does-google-think-vermont-is-in-morristown/Content?oid=3348157)
# and a stackoverflow post: 
# https://stackoverflow.com/questions/36991606/how-does-google-maps-represent-an-area-as-a-point
# . . . the mystery of Vermont's Nullyard has not been satisfactorily explained.


######################################################################
# DAY 20: POPULATION
######################################################################

# When I was growing up in Vermont in the 80s and 90s, I was tought (mostly
# in school environments) that before Europeans arrived Vermont
# was a hunting ground occasionally visited by Iroqouis and Algonquin,
# but certainly not settled. I was tought that Vermont was no one's homeland,
# so it was "available" to first the French then the English.
# But the Abenaki did live here, they still live here, and they did not agree 
# to the erasure. This is an attempt to show where the Abenaki and their
# compatriots live today around the state.

# Get the enriched census block boundaries for the state
wget -c https://opendata.arcgis.com/datasets/541094d3d7db43469fb17d40468c6320_19.zip?outSR=%7B%22latestWkid%22%3A32145%2C%22wkid%22%3A32145%7D -O vt_blocks.zip
unzip vt_blocks.zip

ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" VT_2010_Census_Block_Boundaries_and_Statistics.shp -nln vt_blocks -nlt MULTIPOLYGON

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day20a;
  CREATE TABLE day20a AS (
    SELECT
      p0030001 AS total_population,
      p0030004 AS american_indian,
      ST_Centroid(wkb_geometry) AS the_geom_32145_point,
      wkb_geometry AS the_geom_32145_poly
    FROM vt_blocks
    WHERE p0030004 > 0
  )
"

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day20b;
  CREATE TABLE day20b (
    band text,
    the_geom_32145 geometry(Point,32145)
  );
  INSERT INTO day20b VALUES
    (
      'Missisquoi Band',
      ST_Transform(
        ST_GeomFromText('POINT(-73.075 44.953)', 4326),
        32145
      )
    ),
    (
      'Nulhegan Band',
      ST_Transform(
        ST_GeomFromText('POINT(-72.216 44.915)', 4326),
        32145
      )
    ),
    (
      'Elnu Tribe',
      ST_Transform(
        ST_GeomFromText('POINT(-73.1993 42.817)', 4326),
        32145
      )
    ),
    (
      'Koasek Band',
      ST_Transform(
        ST_GeomFromText('POINT(-72.1286 43.991)', 4326),
        32145
      )
    );
"

# Over 2,000 American Indians live in Vermont today, and while not all of them
# are Abenaki, there are sizeable contingents in certain regions of the state.
# These include the Missisquoi and Nulhegan bands, in the Northern part of the state.
# https://abenakitribe.org/


######################################################################
# DAY 21: WATER
######################################################################

# Hydrography! EVerybody loves figuring out the inflection spots between watersheds, right?
# . . . right?
# Well, anyway, I've always been fascinated by one spot on Route 2 between 
# Joe's Pond and Molly's Pond in Danville. If you empty a glass of water in one spot,
# it flows slowly and steadily into Long Island Sound, but a few feet in the other direction
# and it flows out the Saint Lawrence seaway to the Atlantic. Anyway, let's map that
# spot, and others.

# Get watershed boundaries from VCGI, then import them:
wget -c https://opendata.arcgis.com/datasets/cd19be48c4684255bd63e2873ea418e5_163.zip?outSR=%7B%22latestWkid%22%3A32145%2C%22wkid%22%3A32145%7D -O vt_watersheds.zip
unzip vt_watersheds.zip

ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" Watershed_Planning_Basins.shp -nln vt_watersheds -nlt MULTIPOLYGON

# Simplify a bit for cartographic ease, then render in QGIS
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day21;
  CREATE TABLE day21 AS (
    SELECT
      -- Strip the numeric designations from the names
      split_part(boundary,'(',1) AS name,
      ST_SimplifyVW(wkb_geometry,250) AS the_geom_32145
    FROM vt_watersheds
  )
"

######################################################################
# DAY 22: MOVEMENT
######################################################################

# Roadkill is a fact of life in Vermont. The high speeds of drivers 
# combined with the abundance of wildlife leads to inevitable collisions,
# which at times are catalogued by the local agencies of transportation 
# and natural resources: https://geodata.vermont.gov/datasets/vt-vehicle-animal-collisions-2006

# Let's put this stuff into an animated map of collisions.

# Get and import the data
wget -c https://opendata.arcgis.com/datasets/adc352f98439478d9081a6a7d563f5b2_10.zip?outSR=%7B%22latestWkid%22%3A32145%2C%22wkid%22%3A32145%7D -O vt_collisions.zip
unzip vt_collisions.zip

ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" VT_Vehicle-Animal_Collisions_-_2006.shp -nln vt_collisions -nlt POINT

# Make the layer, parsing the dates and reformatting the animal type
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day22;
  CREATE TABLE day22 AS (
    SELECT
      (CASE WHEN msri_code LIKE 'Deer%' THEN 'Deer' ELSE msri_code END) AS type,
      date_ AS date,
      wkb_geometry AS the_geom_32145
    FROM vt_collisions
  )
"

# Use Anita Graser's excellent Time Manager plugin to animate the result:
# https://www.qgistutorials.com/en/docs/3/animating_time_series.html

# And combine into a gif with imagemagick
convert -delay 50 img/day22/*.png -loop 0 img/day22.gif

######################################################################
# DAY 23: BOUNDARIES
######################################################################

# F*** it. Let's do all the boundaries.
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day23;
  CREATE TABLE day23 AS (
    SELECT wkb_geometry AS the_geom_32145 FROM vt_border
    UNION ALL 
    SELECT wkb_geometry AS the_geom_32145 FROM vt_watersheds
    UNION ALL
    SELECT wkb_geometry AS the_geom_32145 FROM vt_towns
    UNION ALL
    SELECT wkb_geometry AS the_geom_32145 FROM vt_blocks
    -- Now we do some fun stuff with the blocks! 
    -- We DERIVE THINGS *scary grin*
    UNION ALL
    SELECT ST_Union(wkb_geometry) AS the_geom_32145 FROM vt_blocks GROUP BY county
    UNION ALL
    SELECT ST_Union(wkb_geometry) AS the_geom_32145 FROM vt_blocks GROUP BY county,tract
  )
"

######################################################################
# DAY 24: ELEVATION
######################################################################

# Revisiting dayta from many days ago, let's lay some contours on the blender
# hillshade layer. As much as I'd like to do this in PostGIS, there does not
# appear to be a snap-your-fingers-magic-type contour function, so in this
# case we'll use good ol' GDAL:

gdal_contour -a elev data/srtm_30m/srtm_30m_vt_clipped.tif contour_50.shp -i 50.0

# Then put it in the DB
ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" contour_50.shp -nln vt_contours_50

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day24;
  CREATE TABLE day24 AS (
    SELECT
      elev AS elevation_m,
      wkb_geometry AS the_geom_32145
    FROM vt_contours_50
  )
"

# Then apply one of the handy cpt-city topographic color schemes in QGIS:
# https://gis.stackexchange.com/questions/94978/elevation-color-ramps-for-dems-in-qgis

######################################################################
# DAY 25: COVID-19
######################################################################

# Taking a step back from the somewhat-frightning network map from day 15,
# We'll grab some time series data at the county level and see if it's possible
# to perform some geometry magic to make (ugh, I hate that Tufte coined this)
# _sparklines_ of an infographic style

# Get the latest data
wget -c https://opendata.arcgis.com/datasets/439e13964dcc44b59c37ab7b481f2ec6_0.csv -O vt_cases.csv

# Pull it into the DB (and we're off to a VERY long race here)
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vt_cases;
  CREATE TABLE vt_cases (
    objectid_1 int,
    objectid int,
    date text,
    map_county text,
    cntygeoid int,
    c_new int,
    c_total int,
    d_new int,
    d_total int,
    t_total int
  );
"
psql maptember_2020 -c "\COPY vt_cases FROM 'vt_cases.csv' CSV HEADER"

# Parameterize the desired metric (new cases)
METRIC=c_new

# Create a starter dataset with county centroids and correct formatting
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vt_covid;
  CREATE TABLE vt_covid AS (
    WITH counties AS (
      SELECT
        state || county AS id,
        ST_Centroid(ST_Union(wkb_geometry)) AS the_geom_32145
      FROM vt_blocks
      GROUP BY state,county
    )
    SELECT
      c.id,
      v.map_county,
      v.date::date AS date,
      v.c_new,
      v.c_total,
      v.d_new,
      v.d_total,
      v.t_total,
      c.the_geom_32145
    FROM vt_cases v
    LEFT JOIN counties c ON c.id = v.cntygeoid::text
    ORDER BY v.date::date
  )
"

# Create sparklines
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day25;
  CREATE TABLE day25 AS (
    WITH nodes AS (
      SELECT
        map_county,
        date,
        ST_Translate(
          -- Move the individual points to the right place
          ST_Translate(
            the_geom_32145,
            -- Move on the X axis by time (number of days)
            (
              -- Total span of the time series
              DATE_PART('day', current_timestamp - '2020-03-07') -
              -- minus the duration of the given instance
              DATE_PART('day', current_timestamp - date) 
              -- multiplied by a spacer
              * 200
            ),
            -- Move on the Y axis by the metric magnitude * 1/2km
            ${METRIC} * 500
          ),
          -- Move each series back to the right position on the X axis
          DATE_PART('day', current_timestamp - '2020-03-07') / 2 * 200,
          -- And move the by Y a tiny random to avoid overlap
          (CASE WHEN map_county IN ('Windsor County','Windham County') THEN - 15000 ELSE 0 END)
        ) AS the_geom_32145
      FROM vt_covid
    )
    SELECT
      map_county,
      -- Smooth the lines a LITTLE bit
      ST_Simplify(
        -- String the points together by county, ordered by date
        ST_MakeLine(
          array_agg(
            the_geom_32145 
            ORDER BY date
          )
        ),
        500
      ) AS the_geom_32145
    FROM nodes
    GROUP BY map_county
  )
"

# And make a quick county centroids layer for labeling
psql maptember_2020 -c "
  DROP TABLE IF EXISTS vt_county_points;
  CREATE TABLE  vt_county_points AS (
    SELECT
      map_county,
      ST_Centroid(the_geom_32145) AS the_geom_32145
    FROM day25
  )
"

######################################################################
# DAY 26: NEW TOOL
######################################################################

# Over the long, isolated summer, Topi Tjukanov put together some amazing
# SVG polygon styles for use in QGIS. You can get them here:
# https://github.com/tjukanovt/qgis_styles

git clone https://github.com/tjukanovt/qgis_styles.git
cd qgis_styles
cat collections/style_xml/pencilish.xml | pbcopy

# . . . and add to QGIS as indicated in the README!

# . . . using town boundaries
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day26;
  CREATE TABLE day26 AS (
    SELECT *
    FROM vt_towns
  )
"

######################################################################
# DAY 27: BIG DATA (OR SMALL)
######################################################################

# Cheating a bit, I'll move over to Google's BigQuery for today's challenge
# With its hosted mirror of OpenStreetmap, Bigquery can run SQL against the 
# Now-greater-than-2TB complete OSM dataset. Here I'm querying for buildings
# that intersect the Vermont border.

echo "
WITH buildings AS (
SELECT 
  feature_type, 
  osm_id, 
  osm_timestamp, 
  ST_Centroid(geometry) AS centroid, 
  ST_Y(ST_Centroid(geometry)) AS lat,
  ST_X(ST_Centroid(geometry)) AS lon,
  (
    SELECT 
      value 
    FROM UNNEST(all_tags) 
    WHERE key='name'
  ) AS name,
  (
    SELECT 
      value 
    FROM UNNEST(all_tags) 
    WHERE key='height'
  ) AS height
FROM `bigquery-public-data.geo_openstreetmap.planet_features`
WHERE ('building') IN (
  SELECT 
    (key) 
  FROM UNNEST(all_tags))
)
SELECT
  buildings.lat,
  buildings.lon
FROM buildings 
LEFT JOIN `bigquery-public-data.geo_us_boundaries.states` s
ON ST_Intersects(buildings.centroid,s.state_geom)
WHERE s.geo_id = '50'
" > query_in.sql

# Then run the above on BQ: https://console.cloud.google.com/bigquery?sq=239220656820:3da36746c0ef4a8d9864ad7a2af8eec5

# Export the results and bring into the local postgres DB to map
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day27;
  CREATE TABLE day27 (
    lat float,
    lon float
  )
"

psql maptember_2020 -c "\COPY day27 FROM 'vt_osm_buildings.csv' CSV HEADER;
  SELECT AddGeometryColumn ('public','day27','the_geom_32145',32145,'GEOMETRY',2);
  UPDATE day27 
  SET the_geom_32145 = ST_Transform(
    ST_GeomFromText(
      'POINT(' || lon || ' ' || lat || ')',
      4326
    ),
    32145
  );
"

######################################################################
# DAY 28: NON-GEOGRAPHIC MAP
######################################################################

# An awesome idea from Andrew Hill in years gone by: use pure PostGIS
# to rearrange a series of geographical features in a non-geographical way.

# To get some stats, let's grab the county subdivision layer from VCGI.
# This layer can be a basket case elsewhere in the country, but in VT
# the units neatly conform to city and town boundaries
wget -c https://opendata.arcgis.com/datasets/01539ba1dec8418b867ec580424405aa_12.zip?outSR=%7B%22latestWkid%22%3A32145%2C%22wkid%22%3A32145%7D -O vt_cousub.zip
unzip vt_cousub.zip 
ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" VT_2010_Census_County_Subdivision_Boundaries_and_Statistics.shp -nln vt_cousub -nlt MULTIPOLYGON


# Work some true PostGIS wizardry
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day28a;
  CREATE TABLE day28a AS (  
    WITH RECURSIVE 
      dims AS (
        SELECT 
          sqrt(sum(ST_Area(wkb_geometry))) * 1.5 as d, 
          sqrt(sum(ST_Area(wkb_geometry))) / 20 as w, 
          count(*) as rows 
        FROM vt_cousub 
        WHERE wkb_geometry IS NOT NULL),   
      geoms AS (
        SELECT 
          wkb_geometry AS the_geom_32145, 
          geoid10, 
          ST_YMax(wkb_geometry)-ST_YMin(wkb_geometry) as height 
        FROM vt_cousub 
        WHERE wkb_geometry IS NOT NULL 
        ORDER BY ST_YMax(wkb_geometry)-ST_YMin(wkb_geometry)  DESC
      ),  
      geomval AS (
        SELECT 
          the_geom_32145, 
          geoid10, 
          row_number() OVER (ORDER BY height DESC) as id 
        FROM geoms
      ),  
      positions(geoid10, the_geom_32145,x_offset,y_offset,new_row,row_offset) AS (     
        (SELECT geoid10, the_geom_32145, 0.0::float, 0.0::float, FALSE, 2 from geomval limit 1)    
        UNION ALL       
        (SELECT 
          (SELECT geoid10 FROM geomval WHERE id = p.row_offset),
          (SELECT the_geom_32145 FROM geomval WHERE id = p.row_offset),
          CASE WHEN p.x_offset < s.d THEN (SELECT (s.w+(ST_XMax(the_geom_32145) - ST_XMin(the_geom_32145)))+p.x_offset FROM geomval WHERE id = p.row_offset) ELSE 0 END as x_offset,
          CASE WHEN p.x_offset < s.d THEN p.y_offset ELSE (SELECT (s.w+(ST_YMax(the_geom_32145) - ST_YMin(the_geom_32145)))+p.y_offset FROM geomval WHERE id = p.row_offset) END as y_offset , FALSE, p.row_offset+1 
        FROM positions p, dims s 
        WHERE p.row_offset < s.rows ) 
      ),  
      sfact AS (    
        SELECT 
          ST_XMin(the_geom_32145) as x, 
          ST_YMax(the_geom_32145) as y 
        FROM geomval LIMIT 1  
      ),
      arrangement AS (
        SELECT 
          ST_Translate( the_geom_32145, ((x * 1.25) - ST_XMin(the_geom_32145) - (x_offset * 0.75)), (y - ST_YMin(the_geom_32145) - y_offset)) as the_geom_32145, 
          geoid10
        FROM positions,sfact 
        ORDER BY row_offset ASC
      ) 
      SELECT
        arrangement.the_geom_32145,
        arrangement.geoid10,
        vt_cousub.name10 AS name,
        vt_cousub.p0030001 AS pop_2010
      FROM arrangement
      LEFT JOIN vt_cousub ON vt_cousub.geoid10 = arrangement.geoid10
  );
"

# . . . and add a centroid layer for visualizing
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day28b;
  CREATE TABLE day28b AS (
    SELECT
      *,
      ST_Centroid(the_geom_32145) AS the_geom_centroid_32145
    FROM day28a
  );
"

######################################################################
# DAY 29: GLOBE
######################################################################

# Hurray for orthographic projections! Ben (@BNHRdotXYZ) has an
# excellent tutorial on how to add these to QGIS
# https://bnhr.xyz/2018/09/21/create-a-globe-in-QGIS.html

# Get world land!
wget -c https://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/physical/ne_10m_land.zip
unzip ne_10m_land.zip
ogr2ogr -t_srs "EPSG:4326" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" ne_10m_land.shp -nln ne_10m_land -nlt MULTIPOLYGON

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day29;
  CREATE TABLE day29 AS (
    SELECT
      'Land'::text AS type,
      ST_Union(wkb_geometry) AS the_geom
    FROM ne_10m_land
    GROUP BY 1
    UNION ALL
    SELECT
      'Vermont'::text AS type,
      ST_Transform(wkb_geometry,4326) AS the_geom
    FROM vt_border
  );
"

######################################################################
# DAY 30: A MAP
######################################################################

# Nineteen years ago I started hiking the Long Trail, along the spine
# of the Green Mountains from Quebec to Massachusetts. I finished this
# October. Here I break up the segments of the journey by year.

# Get trail data from VCGI:
wget -c https://opendata.arcgis.com/datasets/df69f82eb91e492d89223ae50d2f89b5_21.zip?outSR=%7B%22latestWkid%22%3A32145%2C%22wkid%22%3A32145%7D -O vt_trails.zip
unzip vt_trails.zip
ogr2ogr -where "trailname like 'Long Trail%'" -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" VT_Data_-_E911_Trails.shp -nln vt_long_trail 

# Get my trip log data from github
wget -c https://gist.githubusercontent.com/wboykinm/5562553d0494af27e20ac68a6a4226ff/raw/5cf0235c6a137943adf3b6ea3dc7a879a022f28f/map.geojson -O bill_lt.geojson
ogr2ogr -t_srs "EPSG:32145" -f "PostgreSQL" PG:"host=localhost dbname=maptember_2020" bill_lt.geojson -nln bill_lt 

# Do some crazy stuff to prep the trail into segments by year
psql maptember_2020 -c "
  DROP TABLE IF EXISTS day30a;
  DROP TABLE IF EXISTS day30b;
  CREATE TABLE day30a AS (
    SELECT
      'Long trail'::text AS seg_name,
      ST_Union(wkb_geometry) AS the_geom_32145
    FROM vt_long_trail
    GROUP BY 1
  );
  CREATE TABLE day30b AS (
    SELECT 
      -- Snap these to the closest spot on the line
      year_start,
      year_end,
      ST_ClosestPoint(
        (SELECT the_geom_32145 FROM day30a),
        wkb_geometry
      ) AS the_geom_32145
    FROM bill_lt
  );
"

######################################################################
# FIN. THANKS FOR FOLLOWING!
######################################################################
    