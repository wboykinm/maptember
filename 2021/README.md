# Maptember 2021
It's been a wild year since I last saddled up to make a whole batch of maps! A pandemic waned, waxed, and maybe waned again. A few regimes turned over. Perhaps most pertinently, I took my itinerant mapmaking to [Mapbox](https://www.mapbox.com/), where I work with excellent colleagues on processing satellite imagery.

This year will be a bit more haphazard, a bit less disciplined. I beg your understanding and indulgence, good people of the map. Onward!

## Groundwork
Having a scratch PostGIS database for processing never hurt, so I'll start there.

```sh
createdb maptember_2021
psql maptember_2021 -c "CREATE EXTENSION postgis;"
```

For data, I'll look North (at least at first) to a city I've greatly missed over these two years: Montréal. Données Québec [has an excellent open data page for Montréal](https://www.donneesquebec.ca/organisation/ville-de-montreal/), similar in scope to the [VCGI](https://vcgi.vermont.gov/) resources I used last year. Note there's [some intrigue with download methods](https://www.donneesquebec.ca/foire-aux-questions/#ftp), but `curl` or `wget` seems to do the trick.


## Day 1: Points
The Metro! Let's grab data on the inimitable rubber-tired subway of Montréal, along with all the bus routes.

```sh
cd data/
wget -c http://www.stm.info/sites/default/files/gtfs/stm_sig.zip --no-check-certificate
unzip stm_sig.zip
```

. . . and import it to the database

```sh
ogr2ogr -t_srs "EPSG:4326" -f "PostgreSQL" PG:"dbname=maptember_2021" stm_arrets_sig.shp -overwrite -nln stm_arrets_sig -progress
```

. . . then send it to GeoJSON for import to Mapbox tile service:
```sh
ogr2ogr -t_srs "EPSG:4326" \
  -f "GeoJSON" stm_arrets_sig.geojson \
  PG:"dbname=maptember_2021" \
  -sql "SELECT stop_id,stop_name,loc_type,wkb_geometry FROM stm_arrets_sig" \
  -lco RFC7946=YES
```

. . . where we [style it](https://api.mapbox.com/styles/v1/landplanner/ckvheg58913ya14nb1tns21d7.html?title=copy&access_token=pk.eyJ1IjoibGFuZHBsYW5uZXIiLCJhIjoiY2pmYmpmZmJrM3JjeTMzcGRvYnBjd3B6byJ9.qr2gSWrXpUhZ8vHv-cSK0w&zoomwheel=true&fresh=true#14.36/45.50529/-73.59485/318/65).

![day_1](img/day_1.png)

## Day 2: Lines
The obvious followup to the transit stops is to show the lines themselves!

To PostGIS:
```sh
ogr2ogr -t_srs "EPSG:4326" -f "PostgreSQL" PG:"dbname=maptember_2021" stm_lignes_sig.shp -overwrite -nln stm_lignes_sig -progress
```
To GeoJSON:
```sh
ogr2ogr -t_srs "EPSG:4326" \
  -f "GeoJSON" stm_lignes_sig.geojson \
  PG:"dbname=maptember_2021" \
  -sql "SELECT route_name,wkb_geometry FROM stm_lignes_sig" \
  -lco RFC7946=YES
```

. . . and [back to Mapbox Studio](https://api.mapbox.com/styles/v1/landplanner/ckvih7nfm0wk014lc4cyw0ecd.html?title=copy&access_token=pk.eyJ1IjoibGFuZHBsYW5uZXIiLCJhIjoiY2pmYmpmZmJrM3JjeTMzcGRvYnBjd3B6byJ9.qr2gSWrXpUhZ8vHv-cSK0w&zoomwheel=true&fresh=true#14.36/45.50529/-73.59485/318/65).

![day_2](img/day_2.png)

## Day 3: Polygons
Let's actually pre-grab a bunch of data. This is good stuff.

```sh
# fire stations
wget -c https://data.montreal.ca/dataset/c69e78c6-e454-4bd9-9778-e4b0eaf8105b/resource/beff8ce0-7a61-4a82-95b5-96d89bafa671/download/casernes.geojson
# former admin territories
wget -c https://data.montreal.ca/dataset/87fb795b-f0aa-414d-a38e-f896d13a14ae/resource/ab340339-ef7a-4112-970a-323a6b24a58e/download/anciennes-municipalites.geojson
# administrative bounds
wget -c https://data.montreal.ca/dataset/00bd85eb-23aa-4669-8f1b-ba9a000e3dd8/resource/e9b0f927-8f75-458c-8fda-b5da65cc8b73/download/limadmin.geojson
# social/community housing
wget -c https://data.montreal.ca/dataset/d26fad0f-2eae-44d5-88a0-2bc699fd2592/resource/1c02ead8-f680-495f-9675-6dd18bd3cad0/download/logsoc_donneesouvertes_20191231.geojson
# electoral catchments
wget -c https://data.montreal.ca/dataset/c4a55dcc-531d-4f5c-b3c2-de73fac021f5/resource/af77dffd-cbba-430a-b526-ada16485a658/download/bassins-electoraux-2021.geojson
# former quarries
wget -c https://data.montreal.ca/dataset/d332b1ef-95af-42d8-a996-7e451f1c6722/resource/56810fb3-18cf-44e5-b402-7dceef468cd8/download/anciennes_carrieres_depot_surface.geojson
# restaurants
wget -c https://data.montreal.ca/dataset/c1d65779-d3cb-44e8-af0a-b9f2c5f7766d/resource/ece728c7-6f2d-4a51-a36d-21cd70e0ddc7/download/businesses.geojson
# POIs
wget -c https://data.montreal.ca/dataset/763fe3b8-cdc3-4b8a-bbbd-a0a9bc587c56/resource/5ca7cdb8-f86f-4038-b5a8-657446c75427/download/lieux_d_interet.geojson
# ecoregions
wget -c https://data.montreal.ca/dataset/942ae48f-ba0c-4e33-bb81-b6da50d9d13d/resource/295d94b9-8515-4a7c-9bc2-0e661582f4d7/download/ecoterritoires.geojson
# police districts
wget -c https://data.montreal.ca/dataset/186892b8-bba5-426c-aa7e-9db8c43cbdfe/resource/e18f0da9-3a16-4ba4-b378-59f698b47261/download/limitespdq.geojson
```

. . . and let's style the city police districts.

To PostGIS:
```sh
ogr2ogr -t_srs "EPSG:4326" -f "PostgreSQL" PG:"dbname=maptember_2021" limitespdq.geojson -overwrite -nln limitespdq -nlt PROMOTE_TO_MULTI -lco GEOMETRY_NAME=the_geom -progress
```

Assign a color scheme (this'll be easier now, rather than later)
```sh
psql maptember_2021 -c "ALTER TABLE limitespdq ADD COLUMN color text;
  UPDATE limitespdq
  SET color = (
    CASE
      WHEN random() < 0.2 THEN '0A92AD'
      WHEN random() BETWEEN 0.2 AND 0.4 THEN '45717A'
      WHEN random() BETWEEN 0.4 AND 0.6 THEN '24E098'
      WHEN random() BETWEEN 0.6 AND 0.8 THEN 'E4615E'
      WHEN random() >= 0.8 THEN 'AD0A4D'
      ELSE '0A92AD'
    END
  );
"
```

To GeoJSON:
```sh
ogr2ogr -t_srs "EPSG:4326" \
  -f "GeoJSON" limitespdq_color.geojson \
  PG:"dbname=maptember_2021" \
  -sql "SELECT color,the_geom FROM limitespdq" \
  -lco RFC7946=YES
```

In [Mapbox Studio](https://api.mapbox.com/styles/v1/landplanner/ckvk65dv1137q14o26si8cre8.html?title=copy&access_token=pk.eyJ1IjoibGFuZHBsYW5uZXIiLCJhIjoiY2pmYmpmZmJrM3JjeTMzcGRvYnBjd3B6byJ9.qr2gSWrXpUhZ8vHv-cSK0w&zoomwheel=true&fresh=true#9.69/45.5074/-73.6783/330.3)

![day_3](img/day_3.png)


## Day 4: Hexagons

## Day 5: Data challenge 1 - OSM
