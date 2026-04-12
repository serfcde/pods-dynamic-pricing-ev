# =============================================================================
# PHASE 1: SYNTHETIC DATA GENERATION
# Project: Dynamic Pricing Analysis for Ride-Sharing EV Fleets
# =============================================================================
# This script generates two datasets:
#   1. trips_data.csv     — 5000 individual ride records
#   2. demand_data.csv    — hourly demand aggregated by zone (7200 rows)
# =============================================================================

# ── 0. Install & Load Packages ───────────────────────────────────────────────
# Run this once if you haven't installed these packages:
# install.packages(c("tidyverse", "lubridate"))

library(tidyverse)   # data manipulation + ggplot2
library(lubridate)   # date/time handling

set.seed(42)         # ensures your random data is reproducible every run


# =============================================================================
# SECTION 1: DEFINE SIMULATION PARAMETERS
# =============================================================================

n_trips <- 5000      # total number of trips to simulate

# City zones — think of these as different parts of a city
# Tier 1 = busy downtown, Tier 3 = quiet suburbs
zones <- c("Downtown", "Airport", "Suburb_North", "Suburb_South", "Midtown")
zone_tier <- c(1, 1, 3, 3, 2)          # 1 = high demand, 3 = low demand
names(zone_tier) <- zones

# Vehicle types and their properties
vehicle_types <- c("EV", "Non-EV")

# Base fare per km (in dollars) by vehicle type
base_fare_per_km <- c(EV = 1.80, `Non-EV` = 1.70)

# Cost per km to the driver (fuel/electricity)
cost_per_km     <- c(EV = 0.12, `Non-EV` = 0.28)

# Peak hours — morning rush and evening rush
peak_hours <- c(7, 8, 9, 17, 18, 19, 20)

# Weather conditions and how they affect surge (multiplier boost)
weather_levels  <- c("Clear", "Rainy", "Foggy", "Stormy")
weather_surge   <- c(Clear = 0.0, Rainy = 0.3, Foggy = 0.15, Stormy = 0.5)


# =============================================================================
# SECTION 2: GENERATE TRIPS_DATA (5000 rows)
# =============================================================================
# Each row = one trip. We simulate realistic correlations:
#   • Surge is higher during peak hours AND bad weather
#   • EV drivers earn slightly more per trip
#   • Distance and duration are correlated (longer trip = more time)

# ── 2a. Time & Date columns ──────────────────────────────────────────────────

# Generate random timestamps spread across 30 days
start_date <- as.POSIXct("2024-01-01 00:00:00")
end_date   <- as.POSIXct("2024-01-30 23:59:59")

trip_timestamps <- as.POSIXct(
  runif(n_trips,
        min = as.numeric(start_date),
        max = as.numeric(end_date)),
  origin = "1970-01-01"
)

trip_hour    <- hour(trip_timestamps)          # 0–23
trip_day     <- wday(trip_timestamps, label = TRUE)   # Mon–Sun
trip_date    <- as.Date(trip_timestamps)
is_weekend   <- trip_day %in% c("Sat", "Sun")
is_peak_hour <- trip_hour %in% peak_hours

# ── 2b. Zone & Vehicle assignment ───────────────────────────────────────────

# Trips are more likely to start in Tier 1 zones (Downtown, Airport)
zone_weights <- c(0.30, 0.25, 0.15, 0.15, 0.15)   # must sum to 1
trip_zone    <- sample(zones, n_trips, replace = TRUE, prob = zone_weights)

# 40% of drivers use EVs (realistic adoption rate)
trip_vehicle <- sample(vehicle_types, n_trips, replace = TRUE,
                       prob = c(0.40, 0.60))

# ── 2c. Weather ─────────────────────────────────────────────────────────────

trip_weather <- sample(weather_levels, n_trips, replace = TRUE,
                       prob = c(0.55, 0.25, 0.12, 0.08))

# ── 2d. Trip Distance & Duration ────────────────────────────────────────────

# Distance varies by zone tier — downtown trips tend to be shorter
zone_distance_mean <- c(Downtown = 4.5, Airport = 18.0,
                        Suburb_North = 9.0, Suburb_South = 8.5,
                        Midtown = 6.0)

trip_distance_km <- pmax(1.0,   # minimum 1 km
                         rnorm(n_trips,
                               mean = zone_distance_mean[trip_zone],
                               sd   = 2.5)
)

# Duration (minutes) — correlated with distance, plus traffic noise
trip_duration_min <- pmax(3,
                          trip_distance_km * 3.2 +        # ~3.2 min per km baseline
                            rnorm(n_trips, mean = 0, sd = 4) +   # random traffic variation
                            ifelse(is_peak_hour, 5, 0)           # +5 min during peak hours
)

# ── 2e. Demand Score (synthetic) ────────────────────────────────────────────
# Higher demand → higher surge. Built from multiple factors.

demand_score <- (
  (1 / zone_tier[trip_zone]) * 40 +          # zone tier effect
    ifelse(is_peak_hour, 30, 0) +               # peak hour boost
    ifelse(is_weekend, 10, 0) +                 # weekend boost
    weather_surge[trip_weather] * 20 +          # weather boost
    rnorm(n_trips, mean = 0, sd = 8)            # random noise
)

# Scale demand score to 0–100
demand_score <- pmin(100, pmax(0, demand_score))

# ── 2f. Surge Multiplier ─────────────────────────────────────────────────────
# Surge is directly driven by demand score
# Formula: 1.0 base + up to 2.0 extra based on demand

surge_multiplier <- round(
  1.0 +
    (demand_score / 100) * 2.0 +             # demand-driven surge
    rnorm(n_trips, mean = 0, sd = 0.1),       # small noise
  2
)

# Cap surge between 1.0x and 3.0x (business rule)
surge_multiplier <- pmin(3.0, pmax(1.0, surge_multiplier))

# ── 2g. Fare & Earnings Calculation ─────────────────────────────────────────
# Base fare depends on distance and vehicle type
# Final fare = base fare × surge multiplier

base_fare <- trip_distance_km * base_fare_per_km[trip_vehicle]
final_fare <- round(base_fare * surge_multiplier, 2)

# Driver earnings = fare collected − operating cost
operating_cost    <- round(trip_distance_km * cost_per_km[trip_vehicle], 2)
driver_earnings   <- round(final_fare - operating_cost, 2)

# Platform commission (20% of fare)
platform_commission <- round(final_fare * 0.20, 2)
driver_net_earnings <- round(driver_earnings - platform_commission, 2)

# ── 2h. Passenger Rating ─────────────────────────────────────────────────────
passenger_rating <- round(
  pmin(5.0, pmax(1.0,
                 rnorm(n_trips, mean = 4.3, sd = 0.5)
  )), 1
)

# ── 2i. Assemble trips_data dataframe ────────────────────────────────────────

trips_data <- tibble(
  trip_id             = paste0("T", sprintf("%05d", 1:n_trips)),
  timestamp           = trip_timestamps,
  date                = trip_date,
  hour                = trip_hour,
  day_of_week         = as.character(trip_day),
  is_weekend          = is_weekend,
  is_peak_hour        = is_peak_hour,
  zone                = trip_zone,
  zone_tier           = zone_tier[trip_zone],
  vehicle_type        = trip_vehicle,
  weather             = trip_weather,
  distance_km         = round(trip_distance_km, 2),
  duration_min        = round(trip_duration_min, 1),
  demand_score        = round(demand_score, 1),
  surge_multiplier    = surge_multiplier,
  base_fare_usd       = round(base_fare, 2),
  final_fare_usd      = final_fare,
  operating_cost_usd  = operating_cost,
  driver_earnings_usd = driver_earnings,
  driver_net_usd      = driver_net_earnings,
  platform_commission = platform_commission,
  passenger_rating    = passenger_rating
)

# ── 2j. Save trips_data ───────────────────────────────────────────────────────

write_csv(trips_data, "trips_data.csv")
cat("✅ trips_data.csv saved —", nrow(trips_data), "rows,",
    ncol(trips_data), "columns\n")

# Quick sanity check
cat("\n── trips_data Summary ──\n")
cat("EV trips      :", sum(trips_data$vehicle_type == "EV"), "\n")
cat("Non-EV trips  :", sum(trips_data$vehicle_type == "Non-EV"), "\n")
cat("Avg surge     :", round(mean(trips_data$surge_multiplier), 3), "\n")
cat("Avg EV earn   : $", round(mean(trips_data$driver_net_usd[trips_data$vehicle_type == "EV"]), 2), "\n")
cat("Avg NonEV earn: $", round(mean(trips_data$driver_net_usd[trips_data$vehicle_type == "Non-EV"]), 2), "\n")


# =============================================================================
# SECTION 3: GENERATE DEMAND_DATA (Hourly zone-level aggregates)
# =============================================================================
# This is a SEPARATE table from trips_data.
# It summarises demand conditions per zone per hour across 30 days.
# Used later by the Random Forest model to predict demand.

# ── 3a. Create the skeleton: every zone × every hour × every day ─────────────

all_dates <- seq(as.Date("2024-01-01"), as.Date("2024-01-30"), by = "day")
all_hours <- 0:23

demand_skeleton <- expand.grid(
  date  = all_dates,
  hour  = all_hours,
  zone  = zones,
  stringsAsFactors = FALSE
) %>%
  as_tibble() %>%
  mutate(
    day_of_week  = weekdays(date),
    is_weekend   = day_of_week %in% c("Saturday", "Sunday"),
    is_peak_hour = hour %in% peak_hours,
    zone_tier    = zone_tier[zone]
  )

n_demand <- nrow(demand_skeleton)    # 30 days × 24 hours × 5 zones = 3600

# ── 3b. Simulate demand features ─────────────────────────────────────────────

# Base trip count driven by zone tier + time
base_count <- case_when(
  demand_skeleton$zone_tier == 1 & demand_skeleton$is_peak_hour ~ rnorm(n_demand, 28, 5),
  demand_skeleton$zone_tier == 1 & !demand_skeleton$is_peak_hour ~ rnorm(n_demand, 12, 4),
  demand_skeleton$zone_tier == 2 & demand_skeleton$is_peak_hour ~ rnorm(n_demand, 18, 4),
  demand_skeleton$zone_tier == 2 & !demand_skeleton$is_peak_hour ~ rnorm(n_demand, 8, 3),
  demand_skeleton$zone_tier == 3 & demand_skeleton$is_peak_hour ~ rnorm(n_demand, 10, 3),
  TRUE                                                           ~ rnorm(n_demand, 4, 2)
)

trip_count <- round(pmax(0, base_count +
                           ifelse(demand_skeleton$is_weekend, 5, 0)))  # weekend bump

# Average demand score for this zone-hour slot
avg_demand_score <- (
  (1 / demand_skeleton$zone_tier) * 40 +
    ifelse(demand_skeleton$is_peak_hour, 28, 0) +
    ifelse(demand_skeleton$is_weekend, 10, 0) +
    rnorm(n_demand, 0, 6)
)
avg_demand_score <- pmin(100, pmax(0, avg_demand_score))

# Average surge for this slot (derived from demand score)
avg_surge <- round(1.0 + (avg_demand_score / 100) * 2.0 +
                     rnorm(n_demand, 0, 0.08), 2)
avg_surge <- pmin(3.0, pmax(1.0, avg_surge))

# Weather for each row (zone-hour slot)
slot_weather      <- sample(weather_levels, n_demand, replace = TRUE,
                            prob = c(0.55, 0.25, 0.12, 0.08))
weather_surge_val <- weather_surge[slot_weather]

# Available drivers (supply side)
available_drivers <- round(pmax(1,
                                trip_count * runif(n_demand, 0.8, 1.3) +
                                  rnorm(n_demand, 0, 2)
))

# EV share among available drivers (%)
ev_driver_share <- round(
  pmin(1, pmax(0,
               rnorm(n_demand, mean = 0.40, sd = 0.08)
  )), 2
)

# ── 3c. Assemble demand_data ──────────────────────────────────────────────────

demand_data <- demand_skeleton %>%
  mutate(
    weather           = slot_weather,
    weather_surge_adj = round(weather_surge_val, 2),
    trip_count        = trip_count,
    avg_demand_score  = round(avg_demand_score, 1),
    avg_surge         = avg_surge,
    available_drivers = available_drivers,
    ev_driver_share   = ev_driver_share,
    demand_supply_ratio = round(trip_count / pmax(1, available_drivers), 3)
  ) %>%
  arrange(date, hour, zone)

# ── 3d. Save demand_data ──────────────────────────────────────────────────────

write_csv(demand_data, "demand_data.csv")
cat("\n✅ demand_data.csv saved —", nrow(demand_data), "rows,",
    ncol(demand_data), "columns\n")

# Quick sanity check
cat("\n── demand_data Summary ──\n")
cat("Zones         :", paste(unique(demand_data$zone), collapse = ", "), "\n")
cat("Date range    :", as.character(min(demand_data$date)),
    "to", as.character(max(demand_data$date)), "\n")
cat("Avg surge     :", round(mean(demand_data$avg_surge), 3), "\n")
cat("Avg trip count:", round(mean(demand_data$trip_count), 1), "\n")


# =============================================================================
# SECTION 4: FINAL VERIFICATION — structure of both datasets
# =============================================================================

cat("\n══════════════════════════════════════════════════\n")
cat("PHASE 1 COMPLETE — Both datasets generated!\n")
cat("══════════════════════════════════════════════════\n\n")

cat("── trips_data columns ──\n")
glimpse(trips_data)

cat("\n── demand_data columns ──\n")
glimpse(demand_data)

cat("\n📁 Files saved in your working directory:\n")
cat("   • trips_data.csv\n")
cat("   • demand_data.csv\n")
cat("\nRun phase2_eda.R next!\n")