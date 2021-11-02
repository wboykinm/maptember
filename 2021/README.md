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

## Day 4: Hexagons

## Day 5: Data challenge 1 - OSM
