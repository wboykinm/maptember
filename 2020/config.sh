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
VT_SRTM=( 'N44W074' 'N44W073' 'N44W072' 'N43W073' 'N43W074' 'N42W073' 'N42W074' )
for t in "${VT_SRTM[@]}"; do
  wget -c http://e4ftl01.cr.usgs.gov/MEASURES/SRTMGL1.003/2000.02.11/${t}.SRTMGL1.hgt.zip -O ${t}.zip
  unzip ${t}.zip
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
# With output in hand . . .

# Get the worldfile from the original
gdal_translate -co "TFW=YES" data/srtm_30m/srtm_30m_vt_scaled.tif data/srtm_30m/srtm_30m_vt_tfw.tif

# Apply it to the blender output (and cross fingers)
cp data/srtm_30m/srtm_30m_vt_tfw.tfw data/srtm_30m/vt_srtm30m_relief.tfw
gdal_translate -a_srs "EPSG:32145" -of GTiff data/srtm_30m/vt_srtm30m_relief.tif data/srtm_30m/vt_srtm30m_relief_geo.tif

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
# and spend some time in the Champlain sea. We'll use the already-imported
# SRTM data and continue looking at Paul Ramsey's PostGIS raster methods
# https://info.crunchydata.com/blog/waiting-for-postgis-3-separate-raster-extension

# Make polygons based on the elevation at the extent of the sea at water 
# height maximum (~183m)

psql maptember_2020 -c "
  DROP TABLE IF EXISTS day16;
  CREATE TABLE day16 AS (
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
"