# =============================================================================
# PHASE 3: RANDOM FOREST — DEMAND PREDICTION
# Project: Dynamic Pricing Analysis for Ride-Sharing EV Fleets
# =============================================================================
# GOAL:
#   Train a Random Forest model that predicts trip_count (demand) for a given
#   zone-hour slot. The predicted demand values are then passed into Phase 4
#   (XGBoost) as an extra feature for surge multiplier prediction.
#
# SECTIONS:
#   1. Load data
#   2. Feature engineering  ← creates is_peak, is_weekend, zone_tier_label,
#                              rolling_avg_demand_3h, weather_flag
#   3. Temporal train/test split  ← day 1–24 = train, day 25–30 = test
#   4. Train Random Forest  ← tune ntree and mtry
#   5. Evaluate  ← RMSE, MAE, R² on test set
#   6. Plots  ← actual vs predicted, feature importance, residuals
#   7. Save predictions  ← demand_data_with_predictions.csv for Phase 4
# =============================================================================
# READS:   demand_data.csv  (from Phase 1)
# SAVES:   demand_data_with_predictions.csv
#          rf_model.rds
#          plot_rf_actual_vs_predicted.png
#          plot_rf_feature_importance.png
#          plot_rf_residuals.png
# =============================================================================


# ── 0. Packages ───────────────────────────────────────────────────────────────
# install.packages(c("tidyverse", "randomForest", "caret", "scales"))

library(tidyverse)      # dplyr, ggplot2
library(randomForest)   # RF model
library(caret)          # RMSE / R² helpers
library(scales)         # axis formatting

set.seed(42)            # reproducibility for RF


# =============================================================================
# SECTION 1: LOAD DATA
# =============================================================================

demand <- read_csv("demand_data.csv", show_col_types = FALSE)

cat("✅ demand_data loaded —", nrow(demand), "rows,", ncol(demand), "cols\n")
cat("   Date range:", as.character(min(demand$date)),
    "→", as.character(max(demand$date)), "\n")
cat("   Zones     :", paste(unique(demand$zone), collapse = ", "), "\n")
cat("   Columns   :", paste(names(demand), collapse = ", "), "\n\n")


# =============================================================================
# SECTION 2: FEATURE ENGINEERING
# =============================================================================
# We build EVERY feature mentioned in the brief, even if some already exist
# in the raw data (we re-derive them cleanly and rename for clarity).

cat("── Section 2: Feature engineering ──\n")

# ── 2a. Basic calendar features ──────────────────────────────────────────────

demand <- demand %>%
  mutate(
    # day_num: numeric day of month (1–30) — used for the temporal split
    day_num      = as.integer(format(date, "%d")),
    
    # is_peak_hour: TRUE if the hour falls in AM or PM rush windows
    # Peak hours defined in Phase 1: 7,8,9 and 17,18,19,20
    is_peak_hour = hour %in% c(7, 8, 9, 17, 18, 19, 20),
    
    # is_weekend: re-derived from date (robust — doesn't rely on Phase 1 flag)
    is_weekend   = weekdays(date) %in% c("Saturday", "Sunday"),
    
    # day_of_week_num: numeric 1=Mon … 7=Sun for the model (factors can't go
    # directly into randomForest without encoding)
    day_of_week_num = as.integer(format(date, "%u"))   # ISO: 1=Mon, 7=Sun
  )

# ── 2b. Zone tier label ───────────────────────────────────────────────────────
# Convert the existing numeric zone_tier (1/2/3) into an ordered factor.
# Tier 1 = high demand (Downtown, Airport)
# Tier 2 = medium demand (Midtown)
# Tier 3 = low demand (Suburb_North, Suburb_South)

demand <- demand %>%
  mutate(
    zone_tier_label = factor(
      case_when(
        zone_tier == 1 ~ "High",
        zone_tier == 2 ~ "Medium",
        zone_tier == 3 ~ "Low"
      ),
      levels = c("Low", "Medium", "High"),   # ordered low → high
      ordered = TRUE
    ),
    
    # zone as a plain unordered factor (RF needs this for splitting)
    zone_factor = factor(zone)
  )

# ── 2c. Weather flag ─────────────────────────────────────────────────────────
# Convert weather text → numeric severity score
# Clear=0, Foggy=1, Rainy=2, Stormy=3
# This gives RF a continuous variable to split on, more useful than a factor

demand <- demand %>%
  mutate(
    weather_flag = case_when(
      weather == "Clear"  ~ 0L,
      weather == "Foggy"  ~ 1L,
      weather == "Rainy"  ~ 2L,
      weather == "Stormy" ~ 3L,
      TRUE ~ 0L
    )
  )

# ── 2d. Rolling average demand — 3-hour window ───────────────────────────────
# For each zone, compute the average trip_count of the PREVIOUS 3 hours.
# This is a lag feature: it captures recent demand momentum.
# Important: we use LAG (not a centred window) to prevent data leakage —
# we only look BACK in time, never forward.

demand <- demand %>%
  arrange(zone, date, hour) %>%         # must be sorted before rolling
  group_by(zone) %>%
  mutate(
    # lag1, lag2, lag3: trip_count from 1, 2, 3 hours ago
    lag1_demand = lag(trip_count, 1),
    lag2_demand = lag(trip_count, 2),
    lag3_demand = lag(trip_count, 3),
    
    # rolling mean of the 3 lags
    rolling_avg_demand_3h = rowMeans(
      cbind(lag1_demand, lag2_demand, lag3_demand),
      na.rm = TRUE
    )
  ) %>%
  ungroup()

# Replace NAs in rolling feature (first 3 rows per zone have no history)
# Fill with the zone's overall mean — safe imputation that doesn't leak
zone_mean_demand <- demand %>%
  group_by(zone) %>%
  summarise(zone_mean = mean(trip_count), .groups = "drop")

demand <- demand %>%
  left_join(zone_mean_demand, by = "zone") %>%
  mutate(
    rolling_avg_demand_3h = if_else(
      is.na(rolling_avg_demand_3h),
      zone_mean,
      rolling_avg_demand_3h
    )
  ) %>%
  select(-zone_mean, -lag1_demand, -lag2_demand, -lag3_demand)  # clean up helpers

# ── 2e. Hour-of-day bins ──────────────────────────────────────────────────────
# Split the 24 hours into 4 named time-of-day buckets.
# Gives RF a categorical alternative to raw hour.

demand <- demand %>%
  mutate(
    time_of_day = factor(
      case_when(
        hour %in% 6:11  ~ "Morning",
        hour %in% 12:16 ~ "Afternoon",
        hour %in% 17:21 ~ "Evening",
        TRUE            ~ "Night"
      ),
      levels = c("Night", "Morning", "Afternoon", "Evening")
    )
  )

# ── 2f. Quick engineering check ──────────────────────────────────────────────

cat("   New columns added:\n")
new_cols <- c("day_num", "is_peak_hour", "is_weekend", "day_of_week_num",
              "zone_tier_label", "zone_factor", "weather_flag",
              "rolling_avg_demand_3h", "time_of_day")
for (col in new_cols) {
  cat("   •", col, "— sample:", paste(head(demand[[col]], 3), collapse=", "), "\n")
}

cat("\n   Rolling avg NAs remaining:",
    sum(is.na(demand$rolling_avg_demand_3h)), "\n")
cat("   Total rows after engineering:", nrow(demand), "\n\n")


# =============================================================================
# SECTION 3: TEMPORAL TRAIN / TEST SPLIT
# =============================================================================
# WHY TEMPORAL: If we split randomly, training rows from Jan 28 would be used
# to predict Jan 5 — the model "sees the future". This inflates R² and makes
# the model useless in production. Using a hard date cutoff is the correct way.
#
# Split: day 1–24 = TRAIN (80%), day 25–30 = TEST (20%)

cat("── Section 3: Temporal train/test split ──\n")

TRAIN_CUTOFF <- 24   # days 1–24 = train

train_df <- demand %>% filter(day_num <= TRAIN_CUTOFF)
test_df  <- demand %>% filter(day_num >  TRAIN_CUTOFF)

cat("   Train rows:", nrow(train_df),
    "| dates:", as.character(min(train_df$date)),
    "→", as.character(max(train_df$date)), "\n")
cat("   Test  rows:", nrow(test_df),
    "| dates:", as.character(min(test_df$date)),
    "→", as.character(max(test_df$date)), "\n")
cat("   Train %:", round(nrow(train_df)/nrow(demand)*100, 1), "%\n\n")


# =============================================================================
# SECTION 4: DEFINE FEATURE SET AND TRAIN RANDOM FOREST
# =============================================================================

cat("── Section 4: Training Random Forest ──\n\n")

# ── 4a. Select features for the model ────────────────────────────────────────
# Target  : trip_count  (what RF predicts)
# Features: a mix of calendar, zone, weather, and engineered lag features

rf_features <- c(
  # Calendar
  "hour",                   # raw hour 0–23
  "day_of_week_num",        # 1=Mon … 7=Sun
  "is_peak_hour",           # TRUE/FALSE peak window
  "is_weekend",             # TRUE/FALSE
  "time_of_day",            # Morning/Afternoon/Evening/Night
  
  # Zone
  "zone_factor",            # zone name as factor (Downtown, Airport…)
  "zone_tier",              # numeric tier 1/2/3
  
  # Weather
  "weather_flag",           # 0=Clear, 1=Foggy, 2=Rainy, 3=Stormy
  "weather_surge_adj",      # numeric surge adjustment from weather
  
  # Supply
  "available_drivers",      # how many drivers are online this hour
  "ev_driver_share",        # % of drivers that are EV
  
  # Lag / rolling
  "rolling_avg_demand_3h",  # mean of last 3 hours' trip_count
  
  # Other demand signals
  "avg_demand_score",       # composite demand score from Phase 1
  "demand_supply_ratio"     # trip_count / available_drivers ratio
)

# Build model formula
rf_formula <- as.formula(
  paste("trip_count ~", paste(rf_features, collapse = " + "))
)

cat("   Target  : trip_count\n")
cat("   Features:", length(rf_features), "predictors\n")
cat("   Formula :", deparse(rf_formula), "\n\n")

# ── 4b. Prepare model-ready dataframes ───────────────────────────────────────
# randomForest() requires factors and no character columns

prep_rf_data <- function(df) {
  df %>%
    select(trip_count, all_of(rf_features)) %>%
    mutate(
      is_peak_hour = as.integer(is_peak_hour),   # TRUE/FALSE → 1/0
      is_weekend   = as.integer(is_weekend),
      time_of_day  = as.integer(time_of_day)     # ordered factor → integer
    ) %>%
    drop_na()   # RF can't handle NAs in predictors
}

train_model <- prep_rf_data(train_df)
test_model  <- prep_rf_data(test_df)

cat("   Train model rows:", nrow(train_model), "\n")
cat("   Test  model rows:", nrow(test_model),  "\n\n")

# ── 4c. Tune mtry ─────────────────────────────────────────────────────────────
# mtry = number of features randomly sampled at each tree split.
# Rule of thumb for regression: mtry ≈ p/3 where p = number of features.
# We also try p/3 ± 2 to pick the best one.

p      <- length(rf_features)
mtry_default <- max(1, floor(p / 3))      # ≈ 4 for 14 features
mtry_vals    <- unique(c(mtry_default - 2,
                         mtry_default,
                         mtry_default + 2,
                         floor(p / 2)))
mtry_vals    <- mtry_vals[mtry_vals >= 1 & mtry_vals <= p]

cat("   Tuning mtry over values:", paste(mtry_vals, collapse = ", "), "\n")
cat("   (Using ntree = 300 for tuning — fast)\n\n")

mtry_results <- tibble(mtry = integer(), oob_mse = numeric())

for (m in mtry_vals) {
  rf_tune <- randomForest(
    rf_formula,
    data       = train_model,
    ntree      = 300,
    mtry       = m,
    importance = FALSE
  )
  oob_mse <- tail(rf_tune$mse, 1)   # out-of-bag MSE from last tree
  mtry_results <- add_row(mtry_results, mtry = m, oob_mse = oob_mse)
  cat("   mtry =", m, "| OOB MSE =", round(oob_mse, 4), "\n")
}

best_mtry <- mtry_results$mtry[which.min(mtry_results$oob_mse)]
cat("\n   Best mtry:", best_mtry, "\n\n")

# ── 4d. Final model — ntree = 500 ─────────────────────────────────────────────
# ntree: more trees = more stable but slower.
# 500 is a solid default; use 300 if it's slow on your machine.

cat("   Training final RF with ntree=500, mtry=", best_mtry, "...\n")

rf_model <- randomForest(
  rf_formula,
  data       = train_model,
  ntree      = 500,
  mtry       = best_mtry,
  importance = TRUE,    # needed for varImpPlot and feature importance
  do.trace   = 100      # print OOB error every 100 trees
)

cat("\n   Final model trained!\n")
print(rf_model)


# =============================================================================
# SECTION 5: EVALUATE ON TEST SET
# =============================================================================

cat("\n── Section 5: Test set evaluation ──\n")

# ── 5a. Generate predictions ─────────────────────────────────────────────────

test_preds <- predict(rf_model, newdata = test_model)
train_preds <- predict(rf_model, newdata = train_model)

# ── 5b. Metrics helper ────────────────────────────────────────────────────────

compute_metrics <- function(actual, predicted, label = "") {
  n      <- length(actual)
  resid  <- actual - predicted
  rmse   <- sqrt(mean(resid^2))
  mae    <- mean(abs(resid))
  ss_res <- sum(resid^2)
  ss_tot <- sum((actual - mean(actual))^2)
  r2     <- 1 - ss_res / ss_tot
  mape   <- mean(abs(resid / pmax(actual, 0.001))) * 100
  
  cat("   ── Metrics:", label, "──\n")
  cat("   RMSE :", round(rmse, 4), " (lower = better)\n")
  cat("   MAE  :", round(mae,  4), " (lower = better)\n")
  cat("   R²   :", round(r2,   4), " (closer to 1 = better)\n")
  cat("   MAPE :", round(mape, 2), "%\n\n")
  
  invisible(list(rmse=rmse, mae=mae, r2=r2, mape=mape,
                 actual=actual, predicted=predicted))
}

train_metrics <- compute_metrics(train_model$trip_count, train_preds, "TRAIN")
test_metrics  <- compute_metrics(test_model$trip_count,  test_preds,  "TEST")

# ── 5c. Overfitting check ────────────────────────────────────────────────────
# If train R² >> test R², the model is memorising rather than generalising.

r2_gap <- train_metrics$r2 - test_metrics$r2
cat("   Overfitting gap (train R² − test R²):", round(r2_gap, 4), "\n")
if (r2_gap > 0.15) {
  cat("   ⚠️  Gap > 0.15 — consider increasing mtry or reducing ntree\n\n")
} else {
  cat("   ✅ Gap within acceptable range\n\n")
}

# ── 5d. Residual stats ────────────────────────────────────────────────────────

residuals_test <- test_model$trip_count - test_preds
cat("   Test residuals:\n")
cat("   Mean    :", round(mean(residuals_test), 4), " (should be ~0)\n")
cat("   SD      :", round(sd(residuals_test), 4), "\n")
cat("   Min/Max :", round(min(residuals_test), 2),
    "/", round(max(residuals_test), 2), "\n\n")


# =============================================================================
# SECTION 6: PLOTS
# =============================================================================

cat("── Section 6: Generating evaluation plots ──\n")

project_theme <- theme_minimal(base_size = 12) +
  theme(
    plot.title       = element_text(face = "bold", size = 13,
                                    margin = ggplot2::margin(b = 5)),
    plot.subtitle    = element_text(size = 10, color = "grey45",
                                    margin = ggplot2::margin(b = 10)),
    plot.caption     = element_text(size = 9, color = "grey55"),
    legend.position  = "bottom",
    panel.grid.minor = element_blank(),
    panel.grid.major = element_line(color = "grey92"),
    plot.background  = element_rect(fill = "white", color = NA)
  )

# ── 6a. Actual vs Predicted scatter ──────────────────────────────────────────

eval_df <- tibble(
  actual    = test_model$trip_count,
  predicted = test_preds,
  residual  = residuals_test,
  zone      = test_df$zone[1:length(test_preds)]
)

# Perfect prediction line
pred_range <- range(c(eval_df$actual, eval_df$predicted))

p_avp <- ggplot(eval_df, aes(x = actual, y = predicted, color = zone)) +
  
  # 45-degree perfect-prediction reference line
  geom_abline(slope = 1, intercept = 0,
              linetype = "dashed", color = "grey40", linewidth = 0.8) +
  
  geom_point(size = 2, alpha = 0.65) +
  
  # Smooth loess — deviation from dashed line = model error
  geom_smooth(aes(group = 1), method = "loess", se = TRUE,
              color = "#534AB7", fill = "#EEEDFE",
              linewidth = 0.8, alpha = 0.3) +
  
  # Metrics annotation box
  annotate("label",
           x = pred_range[1] + 0.05 * diff(pred_range),
           y = pred_range[2] - 0.05 * diff(pred_range),
           label = paste0(
             "Test RMSE = ", round(test_metrics$rmse, 2), "\n",
             "Test R²   = ", round(test_metrics$r2,   3), "\n",
             "Test MAE  = ", round(test_metrics$mae,  2)
           ),
           hjust = 0, vjust = 1, size = 3.0,
           fill = "white", color = "grey25",
           label.size = 0.3, label.padding = unit(0.4, "lines")) +
  
  scale_color_manual(
    values = c("Downtown"     = "#534AB7",
               "Airport"      = "#185FA5",
               "Suburb_North" = "#3B6D11",
               "Suburb_South" = "#639922",
               "Midtown"      = "#BA7517"),
    name = "Zone"
  ) +
  scale_x_continuous(labels = label_number(accuracy = 1)) +
  scale_y_continuous(labels = label_number(accuracy = 1)) +
  coord_equal() +
  
  labs(
    title    = "Random Forest — actual vs predicted demand",
    subtitle = "Dashed line = perfect prediction | Points coloured by zone",
    x        = "Actual trip count",
    y        = "Predicted trip count",
    caption  = paste0("Test set: day 25–30 | ntree=500, mtry=", best_mtry)
  ) +
  project_theme

ggsave("plot_rf_actual_vs_predicted.png", p_avp,
       width = 8, height = 7, dpi = 150)
cat("   ✅ plot_rf_actual_vs_predicted.png saved\n")

# ── 6b. Feature importance plot ───────────────────────────────────────────────
# %IncMSE: how much test MSE increases when this variable is permuted (shuffled).
# IncNodePurity: total decrease in node impurity across all trees.
# %IncMSE is more reliable for comparing features across different scales.

imp <- importance(rf_model)
imp_df <- tibble(
  feature    = row.names(imp),
  pct_mse    = imp[, "%IncMSE"],
  node_purity = imp[, "IncNodePurity"]
) %>%
  arrange(desc(pct_mse)) %>%
  mutate(
    feature = factor(feature, levels = rev(feature)),
    rank    = row_number(),
    color_group = case_when(
      rank <= 3  ~ "Top 3",
      rank <= 7  ~ "Mid",
      TRUE       ~ "Low"
    ) %>% factor(levels = c("Top 3", "Mid", "Low"))
  )

p_imp <- ggplot(imp_df,
                aes(x = pct_mse, y = feature, fill = color_group)) +
  
  geom_col(width = 0.65, alpha = 0.88) +
  
  # Value labels at end of bars
  geom_text(aes(label = round(pct_mse, 1)),
            hjust = -0.15, size = 3.0, color = "grey25") +
  
  scale_fill_manual(
    values = c("Top 3" = "#1D9E75", "Mid" = "#185FA5", "Low" = "#888780"),
    name   = "Importance tier"
  ) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.15))) +
  
  labs(
    title    = "Random Forest — feature importance (%IncMSE)",
    subtitle = "Higher = permuting this feature causes bigger prediction error",
    x        = "% increase in MSE when feature is permuted",
    y        = NULL,
    caption  = "IncMSE is more reliable than node purity for cross-feature comparison"
  ) +
  project_theme +
  theme(legend.position = "right")

ggsave("plot_rf_feature_importance.png", p_imp,
       width = 9, height = 6, dpi = 150)
cat("   ✅ plot_rf_feature_importance.png saved\n")

# ── 6c. Residual distribution plot ───────────────────────────────────────────
# Good residuals should be: centred at 0, roughly symmetric, no strong pattern.

resid_df <- tibble(
  residual  = residuals_test,
  predicted = test_preds,
  zone      = test_df$zone[1:length(test_preds)]
)

# Panel A: residual histogram
p_resid_hist <- ggplot(resid_df, aes(x = residual)) +
  geom_histogram(aes(y = after_stat(density)),
                 binwidth = 1, fill = "#185FA5",
                 alpha = 0.7, color = "white", linewidth = 0.2) +
  geom_density(color = "#534AB7", linewidth = 0.9) +
  geom_vline(xintercept = 0, linetype = "dashed",
             color = "grey30", linewidth = 0.7) +
  labs(title = "Residual distribution",
       subtitle = "Should be centred at 0 and roughly symmetric",
       x = "Residual (actual − predicted)", y = "Density") +
  project_theme

# Panel B: residuals vs fitted (checks for heteroscedasticity)
p_resid_fit <- ggplot(resid_df,
                      aes(x = predicted, y = residual, color = zone)) +
  geom_hline(yintercept = 0, linetype = "dashed",
             color = "grey40", linewidth = 0.7) +
  geom_point(size = 1.5, alpha = 0.55) +
  geom_smooth(aes(group = 1), method = "loess", se = FALSE,
              color = "#D85A30", linewidth = 0.8) +
  scale_color_manual(
    values = c("Downtown"     = "#534AB7",
               "Airport"      = "#185FA5",
               "Suburb_North" = "#3B6D11",
               "Suburb_South" = "#639922",
               "Midtown"      = "#BA7517"),
    name = "Zone"
  ) +
  labs(title = "Residuals vs fitted values",
       subtitle = "Red line should stay flat — curve = systematic bias",
       x = "Fitted (predicted trip count)", y = "Residual") +
  project_theme

# Combine side-by-side using cowplot-style patchwork layout
# If you don't have patchwork, save as two separate files:
# ggsave("plot_rf_resid_hist.png", p_resid_hist, width=6, height=5, dpi=150)
# ggsave("plot_rf_resid_fit.png",  p_resid_fit,  width=7, height=5, dpi=150)

# Attempt combined layout (requires patchwork)
tryCatch({
  library(patchwork)
  p_resid_combined <- p_resid_hist + p_resid_fit +
    plot_annotation(
      title   = "Random Forest — residual diagnostics",
      caption = paste0("Test set: days 25–30 | n=", nrow(resid_df), " predictions")
    )
  ggsave("plot_rf_residuals.png", p_resid_combined,
         width = 13, height = 5.5, dpi = 150)
  cat("   ✅ plot_rf_residuals.png saved (combined)\n")
}, error = function(e) {
  # Fallback: save separately if patchwork not installed
  ggsave("plot_rf_residuals_hist.png", p_resid_hist, width=6, height=5, dpi=150)
  ggsave("plot_rf_residuals_fit.png",  p_resid_fit,  width=7, height=5, dpi=150)
  cat("   ✅ plot_rf_residuals_hist.png + plot_rf_residuals_fit.png saved\n")
  cat("      (install patchwork for a single combined file)\n")
})

# ── 6d. OOB error curve ───────────────────────────────────────────────────────
# Shows how the OOB error stabilises as more trees are added.
# Helps validate that ntree=500 was sufficient.

oob_df <- tibble(
  n_trees = seq_along(rf_model$mse),
  oob_mse = rf_model$mse
)

p_oob <- ggplot(oob_df, aes(x = n_trees, y = oob_mse)) +
  geom_line(color = "#185FA5", linewidth = 0.8) +
  geom_vline(xintercept = 300, linetype = "dashed",
             color = "#D85A30", linewidth = 0.6) +
  annotate("text", x = 310, y = max(oob_df$oob_mse) * 0.95,
           label = "ntree=300", hjust = 0, size = 3, color = "#D85A30") +
  scale_y_continuous(labels = label_number(accuracy = 0.01)) +
  labs(
    title    = "OOB error vs number of trees",
    subtitle = "Error should flatten — confirms ntree=500 is sufficient",
    x        = "Number of trees",
    y        = "Out-of-bag MSE",
    caption  = "Dashed line = ntree=300 reference point"
  ) +
  project_theme

ggsave("plot_rf_oob_curve.png", p_oob, width = 8, height = 4.5, dpi = 150)
cat("   ✅ plot_rf_oob_curve.png saved\n")


# =============================================================================
# SECTION 7: SAVE MODEL AND PREDICTIONS
# =============================================================================

cat("\n── Section 7: Saving model and predictions ──\n")

# ── 7a. Save the RF model object ──────────────────────────────────────────────
saveRDS(rf_model, "rf_model.rds")
cat("   ✅ rf_model.rds saved\n")
cat("      Load in Phase 4 with: rf_model <- readRDS('rf_model.rds')\n\n")

# ── 7b. Add predicted_demand to the FULL demand dataset ──────────────────────
# We predict on the ENTIRE dataset (not just test), so Phase 4 (XGBoost)
# has a predicted_demand feature for every row.
# Note: train rows use in-sample predictions (slightly optimistic) —
# this is acceptable because XGBoost will be evaluated on its own test split.

demand_full_model <- prep_rf_data(demand) %>%
  select(-trip_count)   # remove target before predicting

demand$predicted_demand <- predict(rf_model, newdata = prep_rf_data(demand))

# Sanity check
cat("   Predicted demand — summary:\n")
cat("   Min   :", round(min(demand$predicted_demand), 2), "\n")
cat("   Max   :", round(max(demand$predicted_demand), 2), "\n")
cat("   Mean  :", round(mean(demand$predicted_demand), 2), "\n")
cat("   NAs   :", sum(is.na(demand$predicted_demand)), "\n\n")

# ── 7c. Save enriched demand dataset ─────────────────────────────────────────
write_csv(demand, "demand_data_with_predictions.csv")
cat("   ✅ demand_data_with_predictions.csv saved\n")
cat("      Rows:", nrow(demand), "| New column: predicted_demand\n\n")


# =============================================================================
# FINAL SUMMARY
# =============================================================================

cat("══════════════════════════════════════════════════════\n")
cat("PHASE 3 COMPLETE — Random Forest trained & evaluated!\n")
cat("══════════════════════════════════════════════════════\n\n")

cat("📊 Model performance:\n")
cat("   Train RMSE:", round(train_metrics$rmse, 3),
    "| R²:", round(train_metrics$r2, 3), "\n")
cat("   Test  RMSE:", round(test_metrics$rmse,  3),
    "| R²:", round(test_metrics$r2,  3), "\n")
cat("   Overfit gap:", round(r2_gap, 3), "\n\n")

cat("📁 Files saved:\n")
cat("   rf_model.rds\n")
cat("   demand_data_with_predictions.csv\n")
cat("   plot_rf_actual_vs_predicted.png\n")
cat("   plot_rf_feature_importance.png\n")
cat("   plot_rf_residuals.png\n")
cat("   plot_rf_oob_curve.png\n\n")

cat("📌 Top features driving demand (from importance plot):\n")
imp_df %>%
  arrange(desc(pct_mse)) %>%
  slice_head(n = 5) %>%
  mutate(rank = row_number()) %>%
  select(rank, feature, pct_mse) %>%
  print()

cat("\n⏭️  Next: Run phase4_xgboost.R\n")
cat("   XGBoost will use predicted_demand as a feature to predict surge_multiplier\n")