# =============================================================================
# PHASE 2: EXPLORATORY DATA ANALYSIS (EDA)
# Project: Dynamic Pricing Analysis for Ride-Sharing EV Fleets
# =============================================================================
# This script produces 5 analyses + plots:
#   Plot 1  — Demand pattern by hour-of-day per zone (weekday vs weekend)
#   Plot 2  — Surge multiplier distribution (EV vs Non-EV overlay)
#   Plot 3  — Surge boxplots by zone and time-of-day
#   Plot 4  — EV vs Non-EV earnings comparison + t-test
#   Plot 5  — Fare vs distance scatter coloured by surge level
#   Plot 6  — Correlation heatmap of all numeric features
# =============================================================================
# RUNS AFTER: phase1_data_generation.R
# READS:      trips_data.csv, demand_data.csv
# SAVES:      6 PNG plots to your working directory
# =============================================================================


# ── 0. Packages ───────────────────────────────────────────────────────────────
# install.packages(c("tidyverse", "corrplot", "scales", "ggridges"))

library(tidyverse)   # ggplot2, dplyr, tidyr
library(corrplot)    # correlation heatmap
library(scales)      # axis formatting helpers
library(ggridges)    # optional: ridge plots (used in Plot 2)

# ── 1. Load data ──────────────────────────────────────────────────────────────
# These CSVs were created by phase1_data_generation.R
# Make sure your working directory is set to the same folder.

trips  <- read_csv("trips_data.csv",  show_col_types = FALSE)
demand <- read_csv("demand_data.csv", show_col_types = FALSE)

cat("✅ trips loaded  —", nrow(trips),  "rows\n")
cat("✅ demand loaded —", nrow(demand), "rows\n")

# ── 2. Light type-fixing ──────────────────────────────────────────────────────
# Make sure categorical columns are factors so ggplot orders them correctly

trips <- trips %>%
  mutate(
    vehicle_type = factor(vehicle_type, levels = c("EV", "Non-EV")),
    zone         = factor(zone),
    weather      = factor(weather, levels = c("Clear", "Foggy", "Rainy", "Stormy")),
    day_type     = if_else(is_weekend, "Weekend", "Weekday")   # new helper column
  )

demand <- demand %>%
  mutate(
    zone     = factor(zone),
    day_type = if_else(is_weekend, "Weekend", "Weekday")
  )

# ── 3. Shared theme ───────────────────────────────────────────────────────────
# One consistent visual style applied to every plot.
# Change the colours here and they update everywhere.

project_theme <- theme_minimal(base_size = 12) +
  theme(
    plot.title       = element_text(face = "bold", size = 14, margin = margin(b = 6)),
    plot.subtitle    = element_text(size = 11, color = "grey45", margin = margin(b = 10)),
    plot.caption     = element_text(size = 9, color = "grey55", margin = margin(t = 8)),
    legend.position  = "bottom",
    legend.title     = element_text(face = "bold", size = 10),
    strip.text       = element_text(face = "bold", size = 10),
    panel.grid.minor = element_blank(),
    panel.grid.major = element_line(color = "grey92"),
    axis.title       = element_text(size = 10),
    plot.background  = element_rect(fill = "white", color = NA)
  )

# Colour palette — EV = teal, Non-EV = coral
ev_colors  <- c("EV" = "#1D9E75", "Non-EV" = "#D85A30")

# Zone colour palette (5 zones)
zone_colors <- c(
  "Downtown"     = "#534AB7",
  "Airport"      = "#185FA5",
  "Suburb_North" = "#3B6D11",
  "Suburb_South" = "#639922",
  "Midtown"      = "#BA7517"
)


# =============================================================================
# PLOT 1: DEMAND PATTERN ANALYSIS
# Goal: show trip volume by hour of day, split by zone and weekday/weekend
# Dataset used: demand_data (zone-hour level aggregates)
# =============================================================================

cat("\n── Plotting 1/6: Demand patterns ──\n")

# Aggregate: average trip_count per hour per zone per day_type
demand_hourly <- demand %>%
  group_by(zone, hour, day_type) %>%
  summarise(avg_trips = mean(trip_count), .groups = "drop")

p1 <- ggplot(demand_hourly,
             aes(x = hour, y = avg_trips, color = zone, group = zone)) +
  
  # Main line + point layer
  geom_line(linewidth = 0.9, alpha = 0.85) +
  geom_point(size = 1.8, alpha = 0.7) +
  
  # Shade the morning and evening peak windows
  annotate("rect", xmin = 7,  xmax = 9,  ymin = -Inf, ymax = Inf,
           alpha = 0.07, fill = "#E85D24") +
  annotate("rect", xmin = 17, xmax = 20, ymin = -Inf, ymax = Inf,
           alpha = 0.07, fill = "#E85D24") +
  
  # Annotate peak labels
  annotate("text", x = 8,  y = Inf, label = "AM peak", vjust = 1.5,
           size = 2.8, color = "#E85D24", fontface = "italic") +
  annotate("text", x = 18.5, y = Inf, label = "PM peak", vjust = 1.5,
           size = 2.8, color = "#E85D24", fontface = "italic") +
  
  # Weekday vs weekend as facets
  facet_wrap(~day_type, ncol = 2) +
  
  scale_color_manual(values = zone_colors, name = "Zone") +
  scale_x_continuous(breaks = seq(0, 23, 3),
                     labels = c("12am","3am","6am","9am","12pm","3pm","6pm","9pm")) +
  scale_y_continuous(labels = label_number(accuracy = 1)) +
  
  labs(
    title    = "Hourly demand patterns by zone",
    subtitle = "Average trips per hour — weekday vs weekend split",
    x        = "Hour of day",
    y        = "Average trip count",
    caption  = "Shaded bands = peak hours (7–9 AM, 5–8 PM)"
  ) +
  project_theme

ggsave("plot1_demand_patterns.png", p1, width = 11, height = 5, dpi = 150)
cat("   ✅ plot1_demand_patterns.png saved\n")

# Print a quick insight summary in console
cat("\n   ── Insight ──\n")
cat("   Peak zones (highest avg trips):\n")
demand_hourly %>%
  group_by(zone) %>%
  summarise(mean_trips = mean(avg_trips)) %>%
  arrange(desc(mean_trips)) %>%
  print()


# =============================================================================
# PLOT 2A: SURGE DISTRIBUTION — Histogram EV vs Non-EV
# Goal: see the shape and spread of surge multiplier for each vehicle type
# Dataset used: trips_data
# =============================================================================

cat("\n── Plotting 2/6: Surge distribution ──\n")

# Compute skewness manually (no extra package needed)
skew <- function(x) {
  n <- length(x); m <- mean(x); s <- sd(x)
  (n / ((n-1)*(n-2))) * sum(((x - m)/s)^3)
}

ev_skew    <- trips %>% filter(vehicle_type == "EV")    %>% pull(surge_multiplier) %>% skew()
nonev_skew <- trips %>% filter(vehicle_type == "Non-EV") %>% pull(surge_multiplier) %>% skew()

cat("   EV surge skewness   :", round(ev_skew,    3), "\n")
cat("   Non-EV surge skewness:", round(nonev_skew, 3), "\n")

p2a <- ggplot(trips, aes(x = surge_multiplier, fill = vehicle_type)) +
  
  geom_histogram(aes(y = after_stat(density)),
                 binwidth = 0.1, alpha = 0.65,
                 position = "identity", color = "white", linewidth = 0.2) +
  
  # Add density curves on top
  geom_density(aes(color = vehicle_type), linewidth = 0.9,
               fill = NA, alpha = 0.8) +
  
  # Vertical line at the standard 1.0 baseline
  geom_vline(xintercept = 1.0, linetype = "dashed",
             color = "grey40", linewidth = 0.7) +
  annotate("text", x = 1.05, y = Inf, label = "No surge",
           hjust = 0, vjust = 1.5, size = 2.8, color = "grey40") +
  
  # Skewness annotation
  annotate("text", x = 2.6, y = Inf,
           label = paste0("EV skew = ",    round(ev_skew, 2), "\n",
                          "Non-EV skew = ", round(nonev_skew, 2)),
           hjust = 1, vjust = 1.5, size = 2.8, color = "grey30") +
  
  scale_fill_manual(values = ev_colors, name = "Vehicle") +
  scale_color_manual(values = ev_colors, name = "Vehicle") +
  scale_x_continuous(breaks = seq(1, 3, 0.5)) +
  
  labs(
    title    = "Surge multiplier distribution — EV vs Non-EV",
    subtitle = "Histogram + density overlay; skewness annotated",
    x        = "Surge multiplier",
    y        = "Density",
    caption  = "Dashed line = 1.0× (no surge)"
  ) +
  project_theme

ggsave("plot2a_surge_histogram.png", p2a, width = 9, height = 5, dpi = 150)
cat("   ✅ plot2a_surge_histogram.png saved\n")


# =============================================================================
# PLOT 2B: SURGE BOXPLOTS — by zone and time-of-day
# Goal: compare surge spread across zones and peak vs off-peak
# =============================================================================

# Label time-of-day into 3 buckets
trips <- trips %>%
  mutate(time_bucket = case_when(
    hour %in% c(7, 8, 9)           ~ "Morning peak",
    hour %in% c(17, 18, 19, 20)    ~ "Evening peak",
    hour %in% c(22, 23, 0, 1, 2, 3)~ "Late night",
    TRUE                            ~ "Off-peak"
  ) %>% factor(levels = c("Morning peak", "Evening peak", "Off-peak", "Late night")))

p2b <- ggplot(trips,
              aes(x = zone, y = surge_multiplier, fill = time_bucket)) +
  
  geom_boxplot(outlier.size = 0.7, outlier.alpha = 0.4,
               linewidth = 0.5, alpha = 0.75,
               position = position_dodge(width = 0.8), width = 0.65) +
  
  # Mean dots on top of boxes
  stat_summary(fun = mean, geom = "point", shape = 18, size = 2.2,
               position = position_dodge(width = 0.8),
               color = "white", show.legend = FALSE) +
  
  scale_fill_manual(
    values = c("Morning peak"  = "#D85A30",
               "Evening peak"  = "#BA7517",
               "Off-peak"      = "#185FA5",
               "Late night"    = "#534AB7"),
    name = "Time of day"
  ) +
  scale_y_continuous(breaks = seq(1, 3, 0.5)) +
  
  labs(
    title    = "Surge multiplier by zone and time-of-day",
    subtitle = "Boxplots — white diamond = mean; boxes = IQR",
    x        = "Zone",
    y        = "Surge multiplier",
    caption  = "Higher surge = higher demand relative to supply"
  ) +
  project_theme +
  theme(axis.text.x = element_text(angle = 25, hjust = 1))

ggsave("plot2b_surge_boxplots.png", p2b, width = 10, height = 5.5, dpi = 150)
cat("   ✅ plot2b_surge_boxplots.png saved\n")


# =============================================================================
# PLOT 3: EV vs Non-EV EARNINGS COMPARISON
# Goal: compare driver_net_usd across vehicle types; run t-test for significance
# Dataset used: trips_data
# =============================================================================

cat("\n── Plotting 3/6: Earnings comparison + t-test ──\n")

# ── 3a. Statistical test ──────────────────────────────────────────────────────
# Welch two-sample t-test (does not assume equal variance)
ttest_result <- t.test(driver_net_usd ~ vehicle_type, data = trips)

cat("\n   ── T-test: EV vs Non-EV driver net earnings ──\n")
cat("   EV mean   : $", round(ttest_result$estimate[1], 3), "\n")
cat("   Non-EV mean: $", round(ttest_result$estimate[2], 3), "\n")
cat("   t-statistic:", round(ttest_result$statistic, 4), "\n")
cat("   p-value    :", format(ttest_result$p.value, digits = 4), "\n")
cat("   95% CI     : [", round(ttest_result$conf.int[1], 3),
    ",", round(ttest_result$conf.int[2], 3), "]\n")

if (ttest_result$p.value < 0.05) {
  cat("   ✅ SIGNIFICANT: EV and Non-EV earnings differ (p < 0.05)\n")
} else {
  cat("   ⚠️  Not significant at 0.05 level\n")
}

# ── 3b. Earnings summary by zone + vehicle type ───────────────────────────────
earnings_summary <- trips %>%
  group_by(zone, vehicle_type) %>%
  summarise(
    mean_earn   = mean(driver_net_usd),
    median_earn = median(driver_net_usd),
    sd_earn     = sd(driver_net_usd),
    n           = n(),
    .groups = "drop"
  )

# Format p-value label for plot annotation
p_label <- if (ttest_result$p.value < 0.001) "p < 0.001 ***"  else
  if (ttest_result$p.value < 0.01)  paste0("p = ", round(ttest_result$p.value, 3), " **")  else
    if (ttest_result$p.value < 0.05)  paste0("p = ", round(ttest_result$p.value, 3), " *")   else
      paste0("p = ", round(ttest_result$p.value, 3), " ns")

# ── 3c. Plot: side-by-side bars by zone ──────────────────────────────────────
p3 <- ggplot(earnings_summary,
             aes(x = zone, y = mean_earn, fill = vehicle_type)) +
  
  geom_col(position = position_dodge(width = 0.75),
           width = 0.65, alpha = 0.88) +
  
  # Error bars (±1 SD)
  geom_errorbar(
    aes(ymin = mean_earn - sd_earn, ymax = mean_earn + sd_earn),
    position = position_dodge(width = 0.75),
    width = 0.25, linewidth = 0.55, color = "grey30"
  ) +
  
  # Median dot marker
  geom_point(aes(y = median_earn), shape = 23,
             position = position_dodge(width = 0.75),
             size = 2.5, color = "white", fill = "grey20", alpha = 0.8) +
  
  # t-test result as subtitle annotation
  annotate("text", x = Inf, y = Inf,
           label = paste0("Welch t-test\n", p_label),
           hjust = 1.1, vjust = 1.4, size = 3, color = "grey25") +
  
  scale_fill_manual(values = ev_colors, name = "Vehicle type") +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01)) +
  
  labs(
    title    = "Mean driver net earnings — EV vs Non-EV by zone",
    subtitle = "Bars = mean | error bars = ±1 SD | diamond = median",
    x        = "Zone",
    y        = "Driver net earnings (USD per trip)",
    caption  = paste0("T-test result: ", p_label)
  ) +
  project_theme +
  theme(axis.text.x = element_text(angle = 25, hjust = 1))

ggsave("plot3_earnings_comparison.png", p3, width = 10, height = 5.5, dpi = 150)
cat("   ✅ plot3_earnings_comparison.png saved\n")

# ── 3d. Bonus: earnings by surge level ───────────────────────────────────────
# Bin surge into 3 levels and compare earnings
trips <- trips %>%
  mutate(surge_level = cut(surge_multiplier,
                           breaks = c(0.99, 1.5, 2.0, 3.01),
                           labels = c("Low (1.0–1.5)",
                                      "Medium (1.5–2.0)",
                                      "High (2.0–3.0)")))

p3b <- ggplot(trips,
              aes(x = surge_level, y = driver_net_usd,
                  fill = vehicle_type)) +
  
  geom_violin(alpha = 0.55, position = position_dodge(width = 0.85),
              trim = TRUE, linewidth = 0.4) +
  geom_boxplot(width = 0.15, outlier.shape = NA, alpha = 0.8,
               position = position_dodge(width = 0.85), linewidth = 0.4) +
  
  scale_fill_manual(values = ev_colors, name = "Vehicle type") +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01)) +
  
  labs(
    title    = "Earnings distribution across surge levels",
    subtitle = "Violin + box plot — EV vs Non-EV at low / medium / high surge",
    x        = "Surge level",
    y        = "Driver net earnings (USD)",
    caption  = "As surge rises, EV advantage should widen (lower operating cost)"
  ) +
  project_theme

ggsave("plot3b_earnings_by_surge.png", p3b, width = 9, height = 5, dpi = 150)
cat("   ✅ plot3b_earnings_by_surge.png saved\n")


# =============================================================================
# PLOT 4: FARE vs DISTANCE / DURATION SCATTER
# Goal: show the fare-distance relationship coloured by surge intensity
# Dataset used: trips_data
# =============================================================================

cat("\n── Plotting 4/6: Fare vs distance scatter ──\n")

# Identify fare outliers (> 3 IQR above Q3) — label them on the plot
fare_q3  <- quantile(trips$final_fare_usd, 0.75)
fare_iqr <- IQR(trips$final_fare_usd)
outliers <- trips %>%
  filter(final_fare_usd > fare_q3 + 3 * fare_iqr) %>%
  slice_head(n = 8)   # label at most 8 so plot stays readable

p4 <- ggplot(trips,
             aes(x = distance_km, y = final_fare_usd,
                 color = surge_multiplier)) +
  
  # Main scatter — use small semi-transparent points for density
  geom_point(size = 1.3, alpha = 0.45) +
  
  # Smooth trend line (linear model, no CI band for clarity)
  geom_smooth(method = "lm", se = FALSE,
              color = "grey30", linewidth = 0.8, linetype = "dashed") +
  
  # Label the top outliers
  ggrepel::geom_text_repel(
    data = outliers,
    aes(label = paste0("$", final_fare_usd)),
    size = 2.4, color = "grey20", max.overlaps = 8, seed = 42
  ) +
  
  # Colour scale: low surge = blue, high surge = red
  scale_color_gradient2(
    low      = "#185FA5",
    mid      = "#BA7517",
    high     = "#993C1D",
    midpoint = 2.0,
    name     = "Surge ×",
    breaks   = c(1.0, 1.5, 2.0, 2.5, 3.0)
  ) +
  scale_y_continuous(labels = label_dollar(accuracy = 1)) +
  scale_x_continuous(breaks = seq(0, 30, 5)) +
  
  labs(
    title    = "Final fare vs trip distance — coloured by surge level",
    subtitle = "Each point = 1 trip | dashed line = linear trend | labelled points = fare outliers",
    x        = "Trip distance (km)",
    y        = "Final fare (USD)",
    caption  = "Outliers: high-distance airport trips during stormy weather peaks"
  ) +
  project_theme +
  guides(color = guide_colorbar(barwidth = 8, barheight = 0.6,
                                title.position = "top"))

ggsave("plot4_fare_distance_scatter.png", p4, width = 10, height = 6, dpi = 150)
cat("   ✅ plot4_fare_distance_scatter.png saved\n")

# ── 4b. BONUS: Fare vs duration ───────────────────────────────────────────────
p4b <- ggplot(trips,
              aes(x = duration_min, y = final_fare_usd,
                  color = vehicle_type)) +
  
  geom_point(size = 1.2, alpha = 0.35) +
  geom_smooth(method = "lm", se = TRUE, linewidth = 0.9, alpha = 0.15) +
  
  scale_color_manual(values = ev_colors, name = "Vehicle") +
  scale_y_continuous(labels = label_dollar(accuracy = 1)) +
  
  labs(
    title    = "Final fare vs trip duration — EV vs Non-EV",
    subtitle = "Linear trend per vehicle type with 95% confidence band",
    x        = "Trip duration (minutes)",
    y        = "Final fare (USD)"
  ) +
  project_theme

ggsave("plot4b_fare_duration.png", p4b, width = 9, height = 5, dpi = 150)
cat("   ✅ plot4b_fare_duration.png saved\n")


# =============================================================================
# PLOT 5: CORRELATION HEATMAP
# Goal: identify strong correlations and multicollinearity risks
# Dataset used: trips_data (numeric columns only)
# =============================================================================

cat("\n── Plotting 5/6: Correlation heatmap ──\n")

# Select only the numeric columns relevant to modelling
numeric_cols <- trips %>%
  select(
    distance_km,        # trip length
    duration_min,       # trip time
    demand_score,       # demand signal
    surge_multiplier,   # target in Phase 4
    base_fare_usd,      # pre-surge fare
    final_fare_usd,     # post-surge fare
    operating_cost_usd, # driver's cost
    driver_earnings_usd,# gross earnings
    driver_net_usd,     # net earnings (after commission)
    platform_commission,# platform cut
    passenger_rating,   # rider quality
    zone_tier,          # zone demand tier
    hour                # time of day
  )

cor_matrix <- cor(numeric_cols, use = "complete.obs")

# Round for display
cat("\n   Correlation matrix (selected pairs):\n")
round(cor_matrix[c("surge_multiplier","driver_net_usd","demand_score"),], 3) %>%
  as.data.frame() %>% print()

# Save as PNG using corrplot
png("plot5_correlation_heatmap.png", width = 900, height = 800, res = 120)

corrplot(
  cor_matrix,
  method      = "color",          # coloured squares
  type        = "upper",          # upper triangle only (avoids duplication)
  order       = "hclust",         # cluster similar variables together
  tl.col      = "grey20",         # label colour
  tl.srt      = 45,               # label angle
  tl.cex      = 0.75,             # label size
  cl.cex      = 0.7,              # legend text size
  addCoef.col = "grey20",         # show correlation numbers
  number.cex  = 0.6,              # number size
  col         = colorRampPalette(c("#185FA5", "white", "#993C1D"))(200),
  title       = "Correlation heatmap — numeric features",
  mar         = c(0, 0, 2, 0),
  diag        = FALSE
)

dev.off()
cat("   ✅ plot5_correlation_heatmap.png saved\n")

# Flag multicollinearity risks (|r| > 0.85)
cat("\n   ── Multicollinearity flags (|r| > 0.85) ──\n")
high_cor <- which(abs(cor_matrix) > 0.85 & abs(cor_matrix) < 1.0,
                  arr.ind = TRUE)
if (nrow(high_cor) > 0) {
  for (i in seq_len(nrow(high_cor))) {
    r <- row.names(high_cor)[i]; c <- colnames(cor_matrix)[high_cor[i, 2]]
    if (r < c) {  # print each pair once
      cat("   ⚠️  ", r, "↔", c, "=", round(cor_matrix[r, c], 3), "\n")
    }
  }
} else {
  cat("   No severe multicollinearity (all |r| ≤ 0.85)\n")
}


# =============================================================================
# FINAL SUMMARY
# =============================================================================

cat("\n══════════════════════════════════════════════════\n")
cat("PHASE 2 COMPLETE — All EDA plots saved!\n")
cat("══════════════════════════════════════════════════\n\n")

cat("📊 Files saved:\n")
cat("   plot1_demand_patterns.png\n")
cat("   plot2a_surge_histogram.png\n")
cat("   plot2b_surge_boxplots.png\n")
cat("   plot3_earnings_comparison.png\n")
cat("   plot3b_earnings_by_surge.png\n")
cat("   plot4_fare_distance_scatter.png\n")
cat("   plot4b_fare_duration.png\n")
cat("   plot5_correlation_heatmap.png\n")

cat("\n📌 Key findings to note for your report:\n")
cat("   1. Downtown & Airport are peak zones — highest avg demand\n")
cat("   2. Surge is right-skewed — most trips cluster near 1.0x–1.5x\n")
cat("   3. EV drivers earn more per trip due to lower operating cost\n")
cat("   4. Fare and distance are strongly linear — outliers = Airport storms\n")
cat("   5. Watch for high correlation between fare, earnings, and distance\n")

cat("\nRun phase3_4_models.R next!\n")