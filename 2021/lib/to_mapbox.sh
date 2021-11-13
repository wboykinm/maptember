#!/bin/bash
# Export and send to a tileset!
# Requires a vector table in the maptember_2021 DB named for the day of the challenge
# e.g. "day_12"

# set the day
DAY=$1
TOKEN="$2"

# activate the token
bash $2

# Export to geojsonl
ogr2ogr -t_srs "EPSG:4326" \
  -f "GeoJSONSeq" ${DAY}.geojson.ld \
  PG:"dbname=maptember_2021" \
  -sql "SELECT * FROM ${DAY}"

# configure and publish
tilesets upload-source landplanner ${DAY}_source ${DAY}.geojson.ld
echo '{
 "version": 1,
 "layers": {
   "'${DAY}'": {
     "source": "mapbox://tileset-source/landplanner/'${DAY}'_source",
     "minzoom": 1,
     "maxzoom": 13
   }
 }
}' > ${DAY}_recipe.json
tilesets create landplanner.${DAY}_tiles --recipe ${DAY}_recipe.json --name "${DAY}"
tilesets publish landplanner.${DAY}_tiles
