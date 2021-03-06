# Prep data for heterotrophic respiration analysis
# Ben Bond-Lamberty January 2017
#
# This is an expensive (in time) script to run, and it depends on a wide
# variety of data not included in this repository; see below.

# Load SRDB; filter for 'good' data (unmanipulated ecosystems, IRGA/GC only, etc);
# spatially match with CRU climate, Max Planck GPP, MODIS GPP (slow), FLUXNET,
# and SoilGrids1km datasets. This is fairly time-intensive, so there is an
# `APPEND_ONLY` option below.

source("0-functions.R")

SCRIPTNAME  	<- "2-prepdata.R"
PROBLEM       <- FALSE

# Downloaded 5 Jan 2017 from https://crudata.uea.ac.uk/cru/data/hrg/cru_ts_3.24/cruts.1609301803.v3.24/tmp/cru_ts3.24.1901.2015.tmp.dat.nc.gz
CRU_TMP <- "~/Data/CRU/cru_ts3.24.1901.2015.tmp.dat.nc.gz"
# Downloaded 5 Jan 2017 from https://crudata.uea.ac.uk/cru/data/hrg/cru_ts_3.24/cruts.1609301803.v3.24/pre/cru_ts3.24.1901.2015.pre.dat.nc.gz
CRU_PRE <- "~/Data/CRU/cru_ts3.24.1901.2015.pre.dat.nc.gz"
# Downloaded 5 Jan 2017 from https://crudata.uea.ac.uk/cru/data/hrg/cru_ts_3.24/cruts.1609301803.v3.24/pet/cru_ts3.24.1901.2015.pet.dat.nc.gz
CRU_PET <- "~/Data/CRU/cru_ts3.24.1901.2015.pet.dat.nc.gz"
# Computed (see 1-cci.R) from data downloaded 6 June 2017 from http://data.ceda.ac.uk/neodc/esacci/soil_moisture/data/daily_files/COMBINED/v02.2/
CCI_MEANS <- "~/Data/ESA-CCI/ESACCI-SOILMOISTURE-L3S-SSMV-COMBINED-fv02.2.nc_means.nc"
# Computed (see 1-cci.R) from data downloaded 6 June 2017 from http://data.ceda.ac.uk/neodc/esacci/soil_moisture/data/daily_files/COMBINED/v02.2/
CCI_STDS <- "~/Data/ESA-CCI/ESACCI-SOILMOISTURE-L3S-SSMV-COMBINED-fv02.2.nc_stds.nc"


APPEND_ONLY <- FALSE

DEFAULT_TRENDLINE <- c(1991, 2010)

library(raster) # 2.5.8


# -----------------------------------------------------------------------------
# For every SRDB record, 'expand' so there's one year per row
expand_datayears <- function(fd) {
  x <- list()
  for(i in seq_len(nrow(fd))) {
    x[[i]] <- tibble(Record_number = fd$Record_number[i],
                     FLUXNET_SITE_ID = fd$FLUXNET_SITE_ID[i],
                     Longitude = fd$Longitude[i],
                     Latitude = fd$Latitude[i],
                     Year = seq(ceiling(fd$Study_midyear[i] - 0.5 - fd$YearsOfData[i] / 2), 
                                floor(fd$Study_midyear[i] - 0.5 + fd$YearsOfData[i] / 2)))
  }
  bind_rows(x)  
}


# -----------------------------------------------------------------------------
# For every SRDB record, find distance and ID of nearest FLUXNET tower 
match_fluxnet <- function(d, fluxnet) {
  library(fossil)  # 0.3.7
  
  printlog("Starting FLUXNET nearest-neighbor matching...")
  x <- d[c("Longitude", "Latitude")]
  y <- fluxnet[c("LOCATION_LONG", "LOCATION_LAT")]
  names(y) <- names(x)
  z <- rbind(x, y)
  coordinates(z) <- ~ Longitude + Latitude
  dists <- fossil::earth.dist(z, dist = FALSE)
  dists <- dists[(nrow(x)+1):nrow(dists), 1:nrow(x)]
  
  d$FLUXNET_DIST <- NA_real_
  d$FLUXNET_SITE_ID <- NA_character_
  for(i in seq_len(nrow(d))) {
    d$FLUXNET_DIST[i] <- dists[,i][which.min(dists[,i])]
    d$FLUXNET_SITE_ID[i] <- fluxnet$SITE_ID[which.min(dists[,i])]
  }
  d  
}


# -----------------------------------------------------------------------------
# Get data for a single point
extract_point <- function(rasterstack, sp, start_layer, nlayers) {
  try({ rasterstack %>%
      raster::extract(sp, layer = start_layer, nl = nlayers) %>%
      mean(na.rm = TRUE) ->
      x
  })
  
  if(is.na(x)) {  # If we don't get a value, try bilinear
    try({ rasterstack %>%
        raster::extract(sp, layer = start_layer, nl = max(2, nlayers), method = "bilinear") %>%
        mean(na.rm = TRUE) ->
        x
    })
  }
  x
}


# -----------------------------------------------------------------------------
# Extract data from a raster brick or raster stack, given vectors of lon/lat/time info
# This is general-purpose and called by both extract_ncdf_data and extract_geotiff_data below
extract_data <- function(rasterstack, varname, lon, lat, midyear, nyears, 
                         file_startyear, file_layers, file_varname,
                         baseline = c(1961, 1990), 
                         trendline = DEFAULT_TRENDLINE,
                         print_every = 100,
                         months_per_layer = 1) {
  
  printlog(SEPARATOR)
  printlog("Starting extraction for varname:", varname)
  
  # Results vectors: variable, variable normal (1961-1990 by default),
  # trend (1991-2010) and trend significance
  x <- normx <- trend <- trend_p <- rep(NA_real_, length(lon))
  
  # Find nearest neighbors for all lon/lat pairs
  for(i in seq_along(lon)) {
    sp <- SpatialPoints(cbind(lon[i], lat[i]))
    
    if(is.null(file_startyear)) {
      start_layer <- nlayers <- 1  # no time dimension
    } else {
      midyear_layer <- (midyear[i] - file_startyear + 1) * (12 / months_per_layer)
      start_layer <- ceiling(midyear_layer - nyears[i] / 2 * (12 / months_per_layer))
      nlayers <- nyears[i] * (12 / months_per_layer)
    }
    
    printit <- print_every & i %% print_every == 0
    if(printit) {
      printlog("Extracting", i, lon[i], lat[i], midyear[i], nyears[i], "- layers", start_layer, 
               "to", start_layer + nlayers - 1, "...")
    }
    
    # Weirdly, raster::extract does not throw an error if we pass it a negative start layer
    # It just rolls merrily along, returning from the beginning of the file
    if(start_layer < 0 | start_layer + nlayers - 1 > file_layers) {
      printlog(varname, "layer out of bounds #", i)
      next
    }
    
    # Extract the information for this point, over as many years as needed, then average
    x[i] <- extract_point(rasterstack, sp, start_layer, nlayers)
    
    if(printit) {
      printlog(varname, "value:", x[i])
    }
    
    # Calculate baseline (normal) data
    if(!is.null(baseline)) {
      start_layer <- max(1, (baseline[1] - file_startyear) * (12 / months_per_layer) + 1)
      nlayers <- (baseline[2] - baseline[1] + 1) * (12 / months_per_layer)
      normx[i] <- extract_point(rasterstack, sp, start_layer, nlayers)
      if(printit) {
        printlog(varname, "normal:", normx[i])
      }
    }
    
    # Extract data for trend calculation
    if(!is.null(trendline)) {
      start_layer <- max(1, (trendline[1] - file_startyear) * (12 / months_per_layer) + 1)
      nlayers <- (trendline[2] - trendline[1] + 1) * (12 / months_per_layer)
      vals <- raster::extract(rasterstack, sp, layer = start_layer, nl = nlayers)
      tibble(year = rep(trendline[1]:trendline[2], each = (12 / months_per_layer)), 
             x = as.numeric(vals)) %>%
        group_by(year) %>%
        summarise(x = mean(x, na.rm = TRUE)) ->
        vals
      
      try({  # to calculate a trend
        m <- lm(x ~ year, data = vals)
        trend[i] <- m$coefficients[2]
        trend_p[i] <- summary(m)$coefficients[2, 4]
      }, silent = TRUE)
      
      if(printit) {
        printlog(varname, "trend:", trend[i], "p =", trend_p[i])
      }
    }
  }
  
  # Assemble output data set and return  
  out <- tibble(x = x)
  names(out) <- c(varname)
  
  if(!is.null(baseline)) {
    out <- bind_cols(out, tibble(normx = normx))
    names(out)[2] <- paste0(varname, "_norm")
  }
  if(!is.null(trendline)) {
    out <- bind_cols(out, tibble(trend = trend, trend_p = trend_p))
    names(out)[3:4] <- paste0(varname, c("_trend", "_trend_p"))
  } 
  out
}

# -----------------------------------------------------------------------------
# Extract MODIS NPP data given vectors of lon/lat/time info
extract_geotiff_data <- function(directory, varname, lon, lat, midyear, nyears, file_startyear,
                                 print_every = 100,
                                 months_per_layer = 1) {
  
  # Decompress if necessary
  zipfiles <- list.files(directory, pattern = "*.tif.gz$", full.names = TRUE)
  for(f in zipfiles) {
    printlog("Decompressing", basename(f))
    R.utils::gunzip(f, remove = FALSE, overwrite = TRUE)
  }
  
  files <- list.files(directory, pattern = "*.tif$", full.names = TRUE)
  printlog("Creating raster stack from", length(files), "files in", directory)
  
  # NB: extracting data from a a stack is **much** slower than from a brick(), as
  # used below. I don't anticipate running this program often enough to care, but FYI.
  nc <- stack(as.list(files))
  
  out <- extract_data(nc, varname, lon, lat, midyear, nyears, 
                      file_startyear = file_startyear, 
                      file_layers = length(nc@layers), #length(files), 
                      baseline = NULL, trendline = NULL, 
                      print_every = print_every, 
                      months_per_layer = months_per_layer)
  
  # Clean up if we decompressed anything
  for(f in zipfiles) {
    printlog("Removing", f)
    file.remove(gsub(".gz$", "", f))  # remove the unzipped file
  }
  
  out
}

# -----------------------------------------------------------------------------
# Extract CRU and Max Planck data given vectors of lon/lat/time info
extract_ncdf_data <- function(filename, lon, lat, midyear, nyears, 
                              file_startyear, varname,
                              baseline = c(1961, 1990),
                              trendline = DEFAULT_TRENDLINE,
                              print_every = 100,
                              months_per_layer = 1) {
  
  assert_that(length(lon) == length(lat))
  assert_that(length(lon) == length(midyear))
  assert_that(length(midyear) == length(nyears))
  
  # Load file, decompressing first if necessary
  compressed <- grepl("gz$", filename)
  if(compressed) {
    printlog("Decompressing", filename)
    ncfile <- R.utils::gunzip(filename, remove = FALSE, overwrite = TRUE)
  } else {
    ncfile <- filename
  }
  nc <- brick(ncfile, varname = varname)
  
  out <- extract_data(nc, varname, lon, lat, midyear, nyears, 
                      file_startyear = file_startyear, file_layers = nc@data@nlayers, 
                      baseline = baseline, trendline = trendline, 
                      print_every = print_every, months_per_layer = months_per_layer)
  
  # Clean up
  if(compressed) {
    printlog("Removing", ncfile)
    file.remove(ncfile)
  }
  out
}


# ==============================================================================
# Main 

openlog(file.path(outputdir(), paste0(SCRIPTNAME, ".log.txt")), sink = TRUE)
printlog("Welcome to", SCRIPTNAME)
all_data <- list()

# -------------- 1. Get SRDB data and filter ------------------- 

srdb <- read_csv("inputs/srdb-data.csv", col_types = "dcicicccccdddddccddccccccccddcdddddcddcddddididdddddddddddcccccddddddddcddddddcdcddddddddddddddddddddddc")
print_dims(srdb)

printlog("Filtering...")
srdb %>%
  filter(!is.na(Longitude), !is.na(Latitude), 
         !is.na(Rs_annual) | !is.na(Rh_annual),
         !is.na(Study_midyear), !is.na(YearsOfData),
         is.na(Duplicate_record),
         # June 4, 2017: going to include managed ecosystem for a response to Referee 1
         # We'll exclude them for the main analysis in script #4
         #         Ecosystem_state != "Managed", 
         Manipulation == "None",
         Meas_method %in% c("IRGA", "Gas chromatography")) %>%
  dplyr::select(Record_number, Study_midyear, Site_name, 
                YearsOfData, Longitude, Latitude, 
                Biome, Ecosystem_type, Ecosystem_state, Leaf_habit, Stage, #Soil_drainage,
                MAT, MAP, Study_temp, Study_precip, Partition_method, Annual_coverage, Meas_interval,
                Rs_annual, Rs_annual_err, Rh_annual, Ra_annual, GPP, ER) ->
  srdb
print_dims(srdb)

stopifnot(!any(duplicated(srdb$Record_number)))

# For Referee 3, print some stats about the data
printlog("Annual coverage in data:")
print(summary(srdb$Annual_coverage))
printlog("Measurement interval in data:")
print(summary(srdb$Meas_interval))
printlog("Coefficient of variability in Rs data:")
print(summary(srdb$Rs_annual_err / srdb$Rs_annual))
printlog("Number of years per 'site':")
srdb %>% 
  mutate(lon = round(Longitude, 2), lat = round(Latitude, 2)) %>% 
  group_by(lon, lat, Site_name, Ecosystem_type, Leaf_habit) %>% 
  summarise(n = n(), yod = mean(YearsOfData)) %>% 
  ungroup %>% 
  dplyr::select(n, yod) %>% 
  summary %>% 
  print

old_data <- tibble()
if(APPEND_ONLY & file.exists(SRDB_FILTERED_FILE)) {
  old_data <- read_csv(SRDB_FILTERED_FILE)
  printlog("Filtering pre-calculated data...")
  srdb <- subset(srdb, !(Record_number %in% old_data$Record_number))
}

if(!nrow(srdb)) {
  closelog()
  stop("No rows of data--nothing to do!")
}


# -------------- 2. SIF ------------------- 

printlog("Joining with SIF data...")
read_csv("inputs/SIF.csv", col_types = "iddidd") %>%
  dplyr::select(Record_number, GOME2_SIF, SCIA_SIF) %>%
  group_by(Record_number) %>%
  summarise_all(mean, na.rm = TRUE) %>%
  right_join(srdb, by = "Record_number") ->
  srdb

stopifnot(!any(duplicated(srdb$Record_number)))


# -------------- 3. FLUXNET ------------------- 

# Start by finding the nearest Fluxnet station, and its distance in km
read_csv("outputs/fluxnet.csv", col_types = "dddddddddccdddcdd") %>%
  filter(!is.na(LOCATION_LONG), !is.na(LOCATION_LAT)) ->
  fluxnet
srdb <- match_fluxnet(srdb, fluxnet)

# Expand the srdb data so that we have an entry for every integer year;
# merge with the Fluxnet data; and put back together
printlog("Building merge data by expanding SRDB years...")
srdb %>%
  dplyr::select(Record_number, Study_midyear, YearsOfData, Longitude, Latitude, FLUXNET_SITE_ID) %>%
  expand_datayears ->
  srdb_expanded

save_data(srdb_expanded)

printlog("Computing FLUXNET means as necessary and merging back in...")
srdb_expanded %>%
  dplyr::select(-Longitude, -Latitude) %>%
  left_join(fluxnet, by = c("FLUXNET_SITE_ID" = "SITE_ID", "Year" = "Year")) %>%
  dplyr::select(-SITE_NAME) %>%
  rename(mat_fluxnet = MAT, map_fluxnet = MAP) %>%
  group_by(FLUXNET_SITE_ID, Record_number, IGBP) %>%
  summarise_all(mean) %>%
  right_join(srdb, by = c("Record_number", "FLUXNET_SITE_ID")) ->
  srdb

printlog("Checking for ecosystem type match between FLUXNET and SRDB")
fem <- rep(FALSE, nrow(srdb))  # 'fluxnet ecosystem match'
for(i in seq_len(nrow(srdb))) {
  igbp <- srdb$IGBP[i]
  et <- srdb$Ecosystem_type[i]
  lh <- srdb$Leaf_habit[i]
  
  if(is.na(igbp)) {
    fem[i] <- FALSE
  } else if(igbp == "CRO") { 
    fem[i] <- et == "Agriculture"
  } else if(igbp %in% c("CSH", "OSH")) {
    fem[i] <- et == "Shrubland"
  } else if(igbp %in% c("DBF", "DNF")) {
    fem[i] <- et == "Forest" & lh %in% c("Deciduous", "Mixed")
  } else if(igbp %in% c("EBF", "ENF")) {
    fem[i] <- et == "Forest" & lh %in% c("Evergreen", "Mixed")
  } else if(igbp == "GRA") {
    fem[i] <- et == "Grassland"
  } else if (igbp == "MF") {
    fem[i] <- et == "Forest"
  } else if (igbp %in% c("SAV", "WSA")) {
    fem[i] <- et == "Savanna"
  } else if (igbp %in% "WET") {
    fem[i] <- et == "Wetland"
  } else {
    stop("Don't know ", igbp)
  }
}
fem[is.na(fem)] <- FALSE
srdb$FLUXNET_ECOSYSTEM_MATCH <- fem

all_data[["srdb"]] <- srdb


# -------------- 3. Match with CRU climate data ------------------- 

all_data[["tmp"]] <- extract_ncdf_data(CRU_TMP, srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, file_startyear = 1901, varname = "tmp")
pre <- extract_ncdf_data(CRU_PRE, srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, file_startyear = 1901, varname = "pre")
all_data[["pre"]] <- pre * 12 # mm/month to mm/yr
pet <- extract_ncdf_data(CRU_PET, srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, file_startyear = 1901, varname = "pet")
all_data[["pet"]] <- pet * 365 # mm/day to mm/yr


# -------------- 4. Match with Max Planck GPP data ------------------- 

fn <- "/Users/d3x290/Data/MaxPlanck/201715151429EnsembleGPP_GL.nc.gz"
# Downloaded 5 Jan 2017 from https://www.bgc-jena.mpg.de/geodb/tmpdnld/201715151429EnsembleGPP_GL.nc
# See https://www.bgc-jena.mpg.de/bgi/index.php/Services/Overview
gpp <- extract_ncdf_data(fn, srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, baseline = NULL, trendline = NULL, file_startyear = 1982, varname = "gpp")
all_data[["gpp"]] <- gpp * 1000 * 60 * 60 * 24 * 365  # Convert from kgC/m2/s to gC/m2/yr

# We also look up Max Planck (MTE) data for the Fluxnet towers
fluxnet_mtegpp <- extract_ncdf_data(fn, fluxnet$LOCATION_LONG, fluxnet$LOCATION_LAT, fluxnet$Year + 0.5, rep(1, nrow(fluxnet)), baseline = NULL, trendline = NULL, file_startyear = 1982, varname = "gpp")
fluxnet_mtegpp <- fluxnet_mtegpp * 1000 * 60 * 60 * 24 * 365  # Convert from kgC/m2/s to gC/m2/yr
names(fluxnet_mtegpp) <- "gpp_mte"


# -------------- 5. Match with MODIS GPP data ------------------- 

# This is the slow step...

dir <- "/Users/d3x290/Data/MODIS_GPP/"
# Downloaded 6 Jan 2017 from http://www.ntsg.umt.edu/project/mod17
modisgpp <- extract_geotiff_data(dir, "modisgpp", srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, file_startyear = 2000)
modisgpp <- modisgpp * 0.1 # scale factor, per README file; results in gC/m2
modisgpp <- modisgpp * 12 # from mean monthly value to annual sum
# There are some crazy (>10,000 gC/m2) values in MODIS GPP. Remove those
modisgpp$modisgpp[modisgpp$modisgpp > 10000] <- NA
all_data[["modisgpp"]] <- modisgpp

# We also look up Max Planck (MTE) data for the Fluxnet towers
fluxnet_modisgpp <- extract_geotiff_data(dir, "modisgpp", fluxnet$LOCATION_LONG, fluxnet$LOCATION_LAT, fluxnet$Year + 0.5, rep(1, nrow(fluxnet)), file_startyear = 2000)
names(fluxnet_modisgpp) <- "gpp_modis"
fluxnet_modisgpp <- fluxnet_modisgpp * 0.1 # scale factor, per README file; results in gC/m2
fluxnet_modisgpp <- fluxnet_modisgpp * 12 # from mean monthly value to annual sum
fluxnet_modisgpp$gpp_modis[fluxnet_modisgpp$gpp_modis > 10000] <- NA
fluxnet %>%
  bind_cols(fluxnet_modisgpp, fluxnet_mtegpp) %>%
  dplyr::select(Year, GPP_DT_VUT_REF, GPP_NT_VUT_REF, SITE_ID, LOCATION_LAT, LOCATION_LONG, LOCATION_ELEV, IGBP, MAT, MAP, gpp_mte, gpp_modis) %>%
  save_data("fluxnet_remotesensing_comparison.csv", scriptfolder = FALSE)


# -------------- 6. Match with SoilGrids1km data ------------------- 

# Downloaded 9 Jan 2017 from ftp://ftp.soilgrids.org/data/archive/12.Apr.2014/
dir <- "/Users/d3x290/Data/soilgrids1km/BLD/"
bd <- extract_geotiff_data(dir, "BD", srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, file_startyear = NULL)
dir <- "/Users/d3x290/Data/soilgrids1km/ORCDRC/"
orc <- extract_geotiff_data(dir, "ORC", srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, file_startyear = NULL)

all_data[["soc"]] <- tibble(SOC = bd$BD * orc$ORC / 1000)  # kg C in top 1 m


# -------------- 7. ISIMIP GPP (Referee 1) ------------------- 

# Received 2 June 2017 from Min Chen
# Dimensions are 360 x 720 x 40 (lat, lon, years 1971-2010)
ISIMIP_GPP <- "ancillary/isimip-gpp/ISIMIP_ensemble_mean.tif"
dir <- "ancillary/isimip-gpp/"
all_data[["isimip"]]  <- extract_geotiff_data(dir, "gpp_isimip", srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, 
                                              file_startyear = 1971,
                                              months_per_layer = 12)


# -------------- 8. ESA CCI soil moisture (Referee 2) ------------------- 

all_data[["sm_mean"]] <- extract_ncdf_data(CCI_MEANS, srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData, 
                                           baseline = c(1978, 2007), trendline = NULL, 
                                           file_startyear = 1978, varname = "sm", months_per_layer = 12)
sm_sd <- extract_ncdf_data(CCI_STDS, srdb$Longitude, srdb$Latitude, srdb$Study_midyear, srdb$YearsOfData,
                           baseline = c(1978, 2007), trendline = NULL, 
                           file_startyear = 1978, varname = "sm", months_per_layer = 12)
names(sm_sd) <- c("sm_sd", "sm_sd_norm")
all_data[["sm_sd"]] <- sm_sd

# -------------- Done!  ------------------- 

# Combine the various spatial data with the SRDB data and save
printlog(SEPARATOR)
printlog("Rows of all data:", paste(unlist(lapply(all_data, nrow)), collapse = ","))
bind_cols(all_data) %>%
  rename(gpp_modis = modisgpp, 
         gpp_beer = gpp, 
         gpp_srdb = GPP,
         gpp_fluxnet = GPP_NT_VUT_REF,
         tmp_hadcrut4 = tmp,
         pre_hadcrut4 = pre,
         mat_hadcrut4 = tmp_norm,
         map_hadcrut4 = pre_norm,
         mat_srdb = MAT,
         map_srdb = MAP) %>%
  bind_rows(old_data) ->
  srdb_filtered


save_data(srdb_filtered, scriptfolder = FALSE, fname = basename(SRDB_FILTERED_FILE))


# -------------- 9. Not done. Prep global grids ------------------- 

GG_PERIOD <- c(1990, 2014)

printlog(SEPARATOR)
printlog("Prep global grids for coverage plot, global flux predictions")
read_csv("inputs/cell_areas/cell_areas.txt", skip = 12, col_names = c("lon", "lat", "area_km2"), col_types = "ddd") %>% 
  filter(area_km2 != -9999) ->
  gridcells

# For each year, extract climate data for each cell
sp <- SpatialPoints(gridcells[c("lon", "lat")])
sl <- (GG_PERIOD[1] - 1901) * 12 + 1
nyears <- GG_PERIOD[2] - GG_PERIOD[1] + 1
nlayers <- nyears * 12

printlog("Reading data from CRU TMP file...")
ncfile <- R.utils::gunzip(CRU_TMP, remove = FALSE, overwrite = TRUE)
nc <- brick(ncfile)
tmp <- raster::extract(nc, sp, layer = sl, nl = nlayers)
file.remove(ncfile)
printlog("Reading data from CRU PRE file...")
ncfile <- R.utils::gunzip(CRU_PRE, remove = FALSE, overwrite = TRUE)
nc <- brick(ncfile)
pre <- raster::extract(nc, sp, layer = sl, nl = nlayers)
file.remove(ncfile)
printlog("Reading data from CRU PET file...")
ncfile <- R.utils::gunzip(CRU_PET, remove = FALSE, overwrite = TRUE)
nc <- brick(ncfile)
pet <- raster::extract(nc, sp, layer = sl, nl = nlayers)
file.remove(ncfile)

printlog("Creating monthly data structure...")
months <- rep(rep(1:12, each = length(sp)), nyears)
years <- rep(GG_PERIOD[1]:GG_PERIOD[2], each = length(sp) * 12)
crudata_monthly <- tibble(lon = rep(gridcells$lon, 12 * nyears),
                          lat = rep(gridcells$lat, 12 * nyears),
                          area_km2 = rep(gridcells$area_km2, 12 * nyears),
                          month = months,
                          year = years,
                          tmp = as.vector(tmp),
                          pre = as.vector(pre),
                          pet = as.vector(pet))
save_data(crudata_monthly, scriptfolder = FALSE, gzip = TRUE)

printlog("Computing annual data...")
crudata_monthly %>%
  dplyr::select(-month) %>%
  group_by(lon, lat, year) %>%
  summarise_all(mean) %>%
  mutate(pre = pre * 12,  # sum, not mean
         pet = pet * 365) ->   # sum, not mean
  crudata_annual
save_data(crudata_annual, scriptfolder = FALSE, gzip = TRUE)

printlog("Computing period data...")
crudata_annual %>%
  dplyr::select(-year) %>%
  group_by(lon, lat) %>%
  summarise_all(mean) ->
  crudata_period
save_data(crudata_period, scriptfolder = FALSE, gzip = TRUE)


printlog("All done with", SCRIPTNAME)
closelog()

if(PROBLEM) warning("There was a problem - see log")
