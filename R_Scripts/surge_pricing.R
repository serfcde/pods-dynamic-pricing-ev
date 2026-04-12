# =============================================================================
# PHASE 4: XGBOOST — SURGE MULTIPLIER PREDICTION
# Project: Dynamic Pricing Analysis for Ride-Sharing EV Fleets
# =============================================================================
# This script does 5 things:
#   STEP 1 — Define surge as target + join predicted_demand from Phase 3
#   STEP 2 — Prepare DMatrix (XGBoost's required input format)
#   STEP 3 — Train XGBoost with 5-fold CV (tune max_depth, eta, nrounds)
#   STEP 4 — Feature importance plot
#   STEP 5 — Surge heatmap: zone × hour coloured by predicted surge
#
# KEY CONCEPT: XGBoost predicts surge at the TRIP level (trips_data).
# predicted_demand comes from Phase 3 (RF on demand_data) and is joined in
# as a zone-hour aggregate feature — it tells XGBoost "how busy was this
# zone at this hour" for every individual trip.
# =============================================================================
# RUNS AFTER: phase3_rf.R
# SAVES:      xgb_model.bin
#             trips_data_with_surge_pred.csv
#             plot_xgb_cv_rmse.png
#             plot_xgb_actual_vs_pred.png
#             plot_xgb_importance.png
#             plot_xgb_surge_heatmap.png
#             plot_xgb_surge_heatmap_ev.png
# =============================================================================


# ── 0. Packages ───────────────────────────────────────────────────────────────
# Run once if needed:
# install.packages(c("tidyverse", "xgboost", "caret", "scales"))

library(tidyverse)   # dplyr, ggplot2, tidyr
library(xgboost)     # XGBoost model
library(caret)       # RMSE helpers
library(scales)      # axis formatting

set.seed(42)


# ── 1. Load data ──────────────────────────────────────────────────────────────

trips  <- read_csv("trips_data.csv",             show_col_types = FALSE)
demand <- read_csv("demand_data_with_predictions.csv",  show_col_types = FALSE)

cat("✅ trips  loaded —", nrow(trips),  "rows\n")
cat("✅ demand loaded —", nrow(demand), "rows (includes predicted_demand from Phase 3)\n\n")


# =============================================================================
# STEP 1: DEFINE SURGE AS TARGET + JOIN PREDICTED DEMAND
# =============================================================================
# Target: surge_multiplier (continuous, range 1.0–3.0)
# This is a REGRESSION task — we predict a decimal number, not a class.
#
# We also need to join predicted_demand from the Phase 3 demand table
# so that each trip row knows the forecasted demand for its zone-hour slot.
# =============================================================================

cat("── STEP 1: Define target + join predicted demand ──\n")

# ── 1a. Prepare trips with all needed columns ─────────────────────────────────

trips <- trips %>%
  mutate(
    # Exact spec match: label <- trips$surge_multiplier
    # (kept as surge_multiplier — we'll refer to it directly)
    
    # Re-derive is_peak for trips (Phase 2 may or may not have added it)
    is_peak      = as.integer(hour %in% c(7:9, 17:20)),
    is_weekend   = as.integer(is_weekend),
    
    # Zone as integer ID (XGBoost needs numeric, not character)
    zone_id = as.integer(factor(zone,
                                levels = c("Downtown","Airport","Midtown",
                                           "Suburb_North","Suburb_South"))),
    
    # Weather severity: numeric 0–3
    weather_severity = case_when(
      weather == "Clear"  ~ 0L,
      weather == "Foggy"  ~ 1L,
      weather == "Rainy"  ~ 2L,
      weather == "Stormy" ~ 3L
    ),
    
    # Vehicle type as binary: EV=1, Non-EV=0
    is_ev = as.integer(vehicle_type == "EV"),
    
    # Day number for temporal split
    day_num = as.integer(date - min(date)) + 1L
  )

# ── 1b. Join predicted_demand from Phase 3 (zone × hour average) ─────────────
# demand_data_with_pred has one row per zone-hour-day.
# We want the AVERAGE predicted demand for each zone-hour pair across all days
# (a stable "expected demand" signal for each zone at each time of day).

demand_lookup <- demand %>%
  group_by(zone, hour) %>%
  summarise(
    predicted_demand   = mean(predicted_demand,   na.rm = TRUE),
    avg_demand_score   = mean(avg_demand_score,   na.rm = TRUE),
    avg_available_drvr = mean(available_drivers,  na.rm = TRUE),
    .groups = "drop"
  )

# Join to trips on zone + hour
trips <- trips %>%
  left_join(demand_lookup, by = c("zone", "hour"))

cat("   ✅ predicted_demand joined —",
    sum(!is.na(trips$predicted_demand)), "rows matched\n")
cat("   Surge range: [", round(min(trips$surge_multiplier), 2),
    ",", round(max(trips$surge_multiplier), 2), "]\n")
cat("   Mean surge:", round(mean(trips$surge_multiplier), 3), "\n\n")


# =============================================================================
# STEP 2: PREPARE DMatrix
# =============================================================================
# XGBoost does NOT work with R data frames directly.
# It needs a special binary matrix object called DMatrix.
# Steps:
#   a) Select only numeric features (no strings, no dates)
#   b) Extract the label vector separately
#   c) Build xgb.DMatrix(features_matrix, label = label_vector)
#
# We also apply the SAME temporal split as Phase 3:
#   train = days 1–24, test = days 25–30
# =============================================================================

cat("── STEP 2: Prepare DMatrix ──\n")

# ── 2a. Feature list (all numeric) ───────────────────────────────────────────
# Exact spec features + extras that help:
#   predicted_demand  — from Phase 3 RF (zone-hour demand forecast)
#   hour              — time of day
#   zone_id           — integer zone code
#   is_peak           — binary rush hour flag
#   is_weekend        — binary weekend flag
#   base_fare_usd     — trip base fare (distance × rate, pre-surge)
#   distance_km       — trip length
# Plus additional features that should improve the model:
#   zone_tier         — demand level of zone (1=high, 3=low)
#   weather_severity  — 0–3 weather impact
#   duration_min      — trip duration
#   is_ev             — vehicle type
#   avg_demand_score  — zone-hour demand signal from Phase 1
#   avg_available_drvr— supply side signal

xgb_features <- c(
  # ── Spec-required ──
  "predicted_demand",   # Phase 3 RF output — demand forecast
  "hour",               # time of day (0–23)
  "zone_id",            # integer zone code (1–5)
  "is_peak",            # 1 = rush hour
  "is_weekend",         # 1 = Saturday/Sunday
  "base_fare_usd",      # pre-surge fare
  "distance_km",        # trip distance
  # ── Additional ──
  "zone_tier",          # 1=high demand zone, 3=low
  "weather_severity",   # 0=clear → 3=stormy
  "duration_min",       # trip duration
  "is_ev",              # EV=1, Non-EV=0
  "avg_demand_score",   # zone-hour demand score (from Phase 1)
  "avg_available_drvr"  # supply: how many drivers available
)

# ── 2b. Temporal split ────────────────────────────────────────────────────────
trips_train <- trips %>% filter(day_num <= 24)
trips_test  <- trips %>% filter(day_num >  24)

cat("   Train trips:", nrow(trips_train), "| Test trips:", nrow(trips_test), "\n")

# ── 2c. Build feature matrices ────────────────────────────────────────────────
# as.matrix() is required — xgb.DMatrix does not accept data frames

X_train <- trips_train %>% select(all_of(xgb_features)) %>% as.matrix()
X_test  <- trips_test  %>% select(all_of(xgb_features)) %>% as.matrix()

# ── 2d. Label vectors ─────────────────────────────────────────────────────────
# Exact spec: label <- trips$surge_multiplier
y_train <- trips_train$surge_multiplier
y_test  <- trips_test$surge_multiplier

# ── 2e. Build DMatrix objects ─────────────────────────────────────────────────
# Exact spec: dtrain <- xgb.DMatrix(X_train, label=y_train)
dtrain <- xgb.DMatrix(X_train, label = y_train)
dtest  <- xgb.DMatrix(X_test,  label = y_test)

cat("   ✅ dtrain built:", nrow(X_train), "rows ×", ncol(X_train), "features\n")
cat("   ✅ dtest  built:", nrow(X_test),  "rows ×", ncol(X_test),  "features\n\n")


# =============================================================================
# STEP 3: TRAIN XGBOOST WITH 5-FOLD CROSS-VALIDATION
# =============================================================================
# Cross-validation strategy:
#   • 5-fold CV on the TRAINING set — finds the best nrounds automatically
#   • We then grid-search max_depth and eta
#   • Final model is trained on full train set using the best params
#
# Parameters explained:
#   objective    = "reg:squarederror"  → MSE loss for regression
#   max_depth    = tree depth (deeper = more complex, risk overfit)
#   eta          = learning rate (smaller = slower but more accurate)
#   subsample    = fraction of rows used per tree (reduces overfit)
#   colsample_bytree = fraction of features used per tree
#   nrounds      = number of boosting iterations (trees)
# =============================================================================

cat("── STEP 3: XGBoost hyperparameter tuning + CV ──\n")
cat("   This runs a grid search over max_depth × eta — please wait...\n\n")

# ── 3a. Define parameter grid ─────────────────────────────────────────────────
# Spec range: max_depth 4–8, eta 0.05–0.3, nrounds 100–500
# We test a manageable 3×3 grid (9 combinations)

max_depth_grid <- c(4, 6, 8)
eta_grid       <- c(0.05, 0.1, 0.3)
nrounds_cv     <- 300   # run CV up to 300 rounds; early stopping will find best

# Results storage
cv_results <- tibble(
  max_depth = integer(),
  eta       = double(),
  best_nrounds  = integer(),
  cv_rmse_mean  = double(),
  cv_rmse_sd    = double()
)

# ── 3b. Grid search loop ──────────────────────────────────────────────────────
for (md in max_depth_grid) {
  for (et in eta_grid) {
    
    params <- list(
      objective        = "reg:squarederror",  # regression with MSE loss
      max_depth        = md,
      eta              = et,
      subsample        = 0.8,     # use 80% of rows per tree
      colsample_bytree = 0.8,     # use 80% of features per tree
      min_child_weight = 3,       # prevents tiny leaf nodes
      gamma            = 0.1,     # minimum loss reduction to split
      eval_metric      = "rmse"
    )
    
    # Exact spec: xgb.cv(params, dtrain, nfold=5, nrounds=200)
    cv_fit <- xgb.cv(
      params            = params,
      data              = dtrain,
      nfold             = 5,
      nrounds           = nrounds_cv,
      early_stopping_rounds = 20,   # stop if no improvement for 20 rounds
      verbose           = 0,        # suppress per-round output
      prediction        = FALSE
    )
    
    best_iter <- cv_fit$best_iteration %||% nrow(cv_fit$evaluation_log)
    best_rmse <- cv_fit$evaluation_log$test_rmse_mean[best_iter]
    best_sd   <- cv_fit$evaluation_log$test_rmse_std[best_iter]
    
    cv_results <- cv_results %>%
      add_row(max_depth    = md,
              eta          = et,
              best_nrounds = best_iter,
              cv_rmse_mean = best_rmse,
              cv_rmse_sd   = best_sd)
    
    cat("   max_depth=", md, "| eta=", et,
        "| best_nrounds=", best_iter,
        "| CV RMSE =", round(best_rmse, 5), "±", round(best_sd, 5), "\n")
  }
}

# ── 3c. Pick best params ──────────────────────────────────────────────────────
best_row      <- cv_results %>% slice_min(cv_rmse_mean, n = 1)
best_depth    <- best_row$max_depth
best_eta      <- best_row$eta
best_nrounds  <- best_row$best_nrounds

cat("\n   ── Best params selected ──\n")
cat("   max_depth =", best_depth, "\n")
cat("   eta       =", best_eta, "\n")
cat("   nrounds   =", best_nrounds, "\n")
cat("   CV RMSE   =", round(best_row$cv_rmse_mean, 5), "\n\n")

# ── 3d. Train final XGBoost on full training set ──────────────────────────────
final_params <- list(
  objective        = "reg:squarederror",
  max_depth        = best_depth,
  eta              = best_eta,
  subsample        = 0.8,
  colsample_bytree = 0.8,
  min_child_weight = 3,
  gamma            = 0.1,
  eval_metric      = "rmse"
)

xgb_model <- xgb.train(
  params  = final_params,
  data    = dtrain,
  nrounds = best_nrounds,
  watchlist = list(train = dtrain, test = dtest),
  verbose   = 0    # set to 1 to see per-round RMSE during training
)

cat("   ✅ Final XGBoost model trained\n\n")

# ── 3e. Plot: CV RMSE grid heatmap ────────────────────────────────────────────
p_cv <- ggplot(cv_results,
               aes(x = factor(eta), y = factor(max_depth),
                   fill = cv_rmse_mean)) +
  
  geom_tile(color = "white", linewidth = 0.6) +
  
  # Annotate each cell with RMSE value
  geom_text(aes(label = round(cv_rmse_mean, 4)),
            size = 3.2, color = "grey15") +
  
  # Mark the best cell with a border
  geom_tile(data = best_row,
            aes(x = factor(eta), y = factor(max_depth)),
            fill = NA, color = "#D85A30", linewidth = 1.5) +
  
  scale_fill_gradient(low = "#B5D4F4", high = "#993C1D",
                      name = "CV RMSE") +
  
  labs(
    title    = "XGBoost 5-fold CV — RMSE grid (max_depth × eta)",
    subtitle = "Lower RMSE = better | orange border = selected best params",
    x        = "Learning rate (eta)",
    y        = "Max tree depth",
    caption  = paste0("Best: max_depth=", best_depth, ", eta=", best_eta,
                      ", nrounds=", best_nrounds)
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title      = element_text(face = "bold"),
    legend.position = "right",
    plot.background = element_rect(fill = "white", color = NA),
    panel.grid      = element_blank()
  )

ggsave("plot_xgb_cv_rmse.png", p_cv, width = 8, height = 5, dpi = 150)
cat("   ✅ plot_xgb_cv_rmse.png saved\n")


# =============================================================================
# STEP 4: EVALUATE + FEATURE IMPORTANCE
# =============================================================================

cat("\n── STEP 4: Evaluation + Feature importance ──\n")

# ── 4a. Predictions on test set ───────────────────────────────────────────────
surge_pred_test <- predict(xgb_model, dtest)

# Clip predictions to valid surge range [1.0, 3.0]
surge_pred_test <- pmin(3.0, pmax(1.0, surge_pred_test))

# Build results dataframe
test_results <- trips_test %>%
  select(date, hour, zone, vehicle_type, surge_multiplier,
         distance_km, is_peak, is_weekend) %>%
  mutate(pred_surge = surge_pred_test,
         residual   = surge_multiplier - pred_surge,
         abs_error  = abs(residual))

# ── 4b. Metrics ───────────────────────────────────────────────────────────────
rmse_xgb <- sqrt(mean(test_results$residual^2))
mae_xgb  <- mean(test_results$abs_error)
ss_res   <- sum(test_results$residual^2)
ss_tot   <- sum((test_results$surge_multiplier - mean(test_results$surge_multiplier))^2)
r2_xgb   <- 1 - ss_res / ss_tot

cat("\n   ── Test set performance ──\n")
cat("   RMSE :", round(rmse_xgb, 5), "\n")
cat("   MAE  :", round(mae_xgb,  5), "\n")
cat("   R²   :", round(r2_xgb,   4), "\n")

if (r2_xgb >= 0.80) cat("   ✅ Strong fit (R² ≥ 0.80)\n")
if (r2_xgb >= 0.60 && r2_xgb < 0.80) cat("   ⚠️  Moderate fit\n")
if (r2_xgb < 0.60)  cat("   ❌ Weak fit — review features\n")

# ── 4c. Actual vs predicted plot ──────────────────────────────────────────────
p_avp <- ggplot(test_results,
                aes(x = surge_multiplier, y = pred_surge)) +
  
  geom_point(aes(color = zone), size = 1.4, alpha = 0.45) +
  geom_abline(slope = 1, intercept = 0,
              linetype = "dashed", color = "grey35", linewidth = 0.8) +
  geom_smooth(method = "lm", se = TRUE, color = "grey20",
              linewidth = 0.8, alpha = 0.12) +
  
  annotate("text",
           x = 1.05, y = 2.9,
           label = paste0("R² = ",   round(r2_xgb,   3),
                          "\nRMSE = ", round(rmse_xgb, 4)),
           hjust = 0, vjust = 1, size = 3.2, color = "grey25") +
  
  scale_color_manual(
    values = c("Downtown"    = "#534AB7",
               "Airport"     = "#185FA5",
               "Midtown"     = "#BA7517",
               "Suburb_North"= "#3B6D11",
               "Suburb_South"= "#639922"),
    name = "Zone"
  ) +
  scale_x_continuous(breaks = seq(1, 3, 0.5), limits = c(1, 3)) +
  scale_y_continuous(breaks = seq(1, 3, 0.5), limits = c(1, 3)) +
  
  labs(
    title    = "XGBoost — Actual vs Predicted surge multiplier (test set)",
    subtitle = "Each point = 1 trip | dashed = perfect prediction",
    x        = "Actual surge multiplier",
    y        = "Predicted surge multiplier",
    caption  = paste0("Test set: days 25–30 | max_depth=", best_depth,
                      ", eta=", best_eta, ", nrounds=", best_nrounds)
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold"),
        plot.background = element_rect(fill = "white", color = NA))

ggsave("plot_xgb_actual_vs_pred.png", p_avp, width = 9, height = 6, dpi = 150)
cat("   ✅ plot_xgb_actual_vs_pred.png saved\n")

# ── 4d. Feature importance ────────────────────────────────────────────────────
# Exact spec: xgb.importance(model=xgb_model) |> xgb.plot.importance()

importance_matrix <- xgb.importance(
  feature_names = xgb_features,
  model         = xgb_model
)

cat("\n   ── Feature importance (top features) ──\n")
print(importance_matrix)

# Save the built-in XGBoost importance plot (matches spec exactly)
png("plot_xgb_importance_builtin.png", width = 800, height = 500, res = 120)
xgb.plot.importance(importance_matrix,
                    main  = "XGBoost Feature Importance",
                    col   = "#185FA5",
                    top_n = length(xgb_features))
dev.off()
cat("   ✅ plot_xgb_importance_builtin.png saved\n")

# Custom ggplot version (cleaner for reports)
p_imp <- importance_matrix %>%
  as_tibble() %>%
  mutate(Feature = factor(Feature, levels = rev(Feature))) %>%
  ggplot(aes(x = Gain, y = Feature)) +
  
  geom_col(aes(fill = Gain), width = 0.65, alpha = 0.88) +
  geom_text(aes(label = round(Gain, 3)),
            hjust = -0.15, size = 3, color = "grey20") +
  
  scale_fill_gradient(low = "#B5D4F4", high = "#185FA5", guide = "none") +
  scale_x_continuous(expand = expansion(mult = c(0, 0.18))) +
  
  labs(
    title    = "XGBoost feature importance — Gain",
    subtitle = "Gain = average improvement in loss when feature is used in a split",
    x        = "Gain (importance score)",
    y        = NULL,
    caption  = paste0("Expected top features: hour + predicted_demand | ",
                      "validates that demand and time drive surge")
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title         = element_text(face = "bold"),
    panel.grid.major.y = element_blank(),
    panel.grid.minor   = element_blank(),
    plot.background    = element_rect(fill = "white", color = NA)
  )

ggsave("plot_xgb_importance.png", p_imp, width = 9, height = 6, dpi = 150)
cat("   ✅ plot_xgb_importance.png saved\n")


# =============================================================================
# STEP 5: SURGE HEATMAP — zone × hour
# =============================================================================
# This is the KEY SLIDE VISUAL:
#   Y-axis = zone
#   X-axis = hour (0–23)
#   Fill   = mean predicted surge for that zone-hour combination
#
# We build this using the FULL trips dataset (all predictions, not just test).
# Then we also make a split version: EV vs Non-EV side-by-side heatmaps.
# =============================================================================

cat("\n── STEP 5: Surge heatmaps ──\n")

# ── 5a. Predict surge for ALL trips ───────────────────────────────────────────
X_all <- trips %>% select(all_of(xgb_features)) %>% as.matrix()
d_all <- xgb.DMatrix(X_all)

all_surge_pred <- predict(xgb_model, d_all)
all_surge_pred <- pmin(3.0, pmax(1.0, all_surge_pred))

trips <- trips %>%
  mutate(pred_surge = all_surge_pred)

# ── 5b. Aggregate: mean predicted surge per zone × hour ───────────────────────
heatmap_data <- trips %>%
  group_by(zone, hour) %>%
  summarise(
    mean_pred_surge   = mean(pred_surge),
    mean_actual_surge = mean(surge_multiplier),
    n_trips           = n(),
    .groups = "drop"
  )

# ── 5c. Main heatmap — Exact spec:
# ggplot(aes(hour, zone, fill=pred_surge)) + geom_tile() ──────────────────────

# Zone ordering: high demand at top → low demand at bottom
zone_order <- c("Downtown", "Airport", "Midtown", "Suburb_North", "Suburb_South")

heatmap_data <- heatmap_data %>%
  mutate(zone = factor(zone, levels = rev(zone_order)))  # rev so Downtown on top

p_heat <- ggplot(heatmap_data,
                 aes(x = hour, y = zone, fill = mean_pred_surge)) +
  
  # Exact spec: geom_tile()
  geom_tile(color = "white", linewidth = 0.4) +
  
  # Annotate each cell with the surge value
  geom_text(aes(label = round(mean_pred_surge, 2)),
            size = 2.6, color = "grey15") +
  
  # Peak hour vertical bands (subtle)
  annotate("rect", xmin = 6.5,  xmax = 9.5,
           ymin = 0.5, ymax = length(zone_order) + 0.5,
           fill = NA, color = "#E85D24", linewidth = 0.8, alpha = 0.6) +
  annotate("rect", xmin = 16.5, xmax = 20.5,
           ymin = 0.5, ymax = length(zone_order) + 0.5,
           fill = NA, color = "#E85D24", linewidth = 0.8, alpha = 0.6) +
  
  # Labels for peak bands
  annotate("text", x = 8,    y = 0.2, label = "AM peak",
           size = 2.6, color = "#E85D24", fontface = "italic") +
  annotate("text", x = 18.5, y = 0.2, label = "PM peak",
           size = 2.6, color = "#E85D24", fontface = "italic") +
  
  scale_fill_gradient2(
    low      = "#B5D4F4",   # low surge = blue
    mid      = "#FAC775",   # medium surge = amber
    high     = "#993C1D",   # high surge = deep red
    midpoint = 2.0,
    name     = "Predicted\nsurge ×",
    limits   = c(1, 3),
    breaks   = c(1.0, 1.5, 2.0, 2.5, 3.0)
  ) +
  scale_x_continuous(
    breaks = seq(0, 23, 3),
    labels = c("12am","3am","6am","9am","12pm","3pm","6pm","9pm")
  ) +
  
  labs(
    title    = "Predicted surge multiplier — zone × hour heatmap",
    subtitle = "Mean XGBoost-predicted surge per zone and time of day | orange = peak windows",
    x        = "Hour of day",
    y        = "Zone (high → low demand)",
    caption  = "Zones ordered by demand tier: Downtown (tier 1) at top → Suburbs (tier 3) at bottom"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title      = element_text(face = "bold"),
    legend.position = "right",
    panel.grid      = element_blank(),
    plot.background = element_rect(fill = "white", color = NA),
    axis.text.y     = element_text(size = 10)
  )

ggsave("plot_xgb_surge_heatmap.png", p_heat, width = 12, height = 5, dpi = 150)
cat("   ✅ plot_xgb_surge_heatmap.png saved\n")

# ── 5d. BONUS: EV vs Non-EV side-by-side heatmap ────────────────────────────
# Does EV surge differ from Non-EV surge? (It shouldn't much — same zone/hour —
# but any difference reveals how vehicle type affects surge assignment.)

heatmap_ev <- trips %>%
  group_by(zone, hour, vehicle_type) %>%
  summarise(mean_pred_surge = mean(pred_surge), .groups = "drop") %>%
  mutate(zone = factor(zone, levels = rev(zone_order)))

p_heat_ev <- ggplot(heatmap_ev,
                    aes(x = hour, y = zone, fill = mean_pred_surge)) +
  
  geom_tile(color = "white", linewidth = 0.4) +
  geom_text(aes(label = round(mean_pred_surge, 2)),
            size = 2.3, color = "grey15") +
  
  facet_wrap(~vehicle_type, ncol = 2,
             labeller = labeller(vehicle_type = c(EV = "EV drivers",
                                                  `Non-EV` = "Non-EV drivers"))) +
  
  scale_fill_gradient2(
    low = "#B5D4F4", mid = "#FAC775", high = "#993C1D",
    midpoint = 2.0, name = "Surge ×",
    limits = c(1, 3), breaks = c(1.0, 1.5, 2.0, 2.5, 3.0)
  ) +
  scale_x_continuous(
    breaks = seq(0, 23, 6),
    labels = c("12am","6am","12pm","6pm")
  ) +
  
  labs(
    title    = "Predicted surge — EV vs Non-EV side-by-side",
    subtitle = "Any difference between panels reveals vehicle-type effects on surge",
    x        = "Hour of day", y = "Zone",
    caption  = "EV advantage: lower cost per km → same surge multiplier = higher net earnings"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title      = element_text(face = "bold"),
    panel.grid      = element_blank(),
    strip.text      = element_text(face = "bold", size = 11),
    plot.background = element_rect(fill = "white", color = NA)
  )

ggsave("plot_xgb_surge_heatmap_ev.png", p_heat_ev, width = 13, height = 5.5, dpi = 150)
cat("   ✅ plot_xgb_surge_heatmap_ev.png saved\n")


# =============================================================================
# STEP 6: SAVE PREDICTIONS + MODEL
# =============================================================================

cat("\n── STEP 6: Saving outputs ──\n")

# Add pred_surge to full trips table
trips_out <- trips %>%
  select(trip_id, date, hour, zone, vehicle_type, surge_multiplier,
         pred_surge, predicted_demand, distance_km, base_fare_usd,
         final_fare_usd, driver_net_usd, is_peak, is_weekend, weather)

write_csv(trips_out, "trips_data_with_surge_pred.csv")
cat("   ✅ trips_data_with_surge_pred.csv saved —",
    nrow(trips_out), "rows\n")

# Save model
xgb.save(xgb_model, "xgb_model.bin")
cat("   ✅ xgb_model.bin saved\n")
cat("      Load with: xgb_model <- xgb.load('xgb_model.bin')\n")


# =============================================================================
# FINAL SUMMARY
# =============================================================================

cat("\n══════════════════════════════════════════════════\n")
cat("PHASE 4 COMPLETE — XGBoost surge model trained!\n")
cat("══════════════════════════════════════════════════\n\n")

cat("📊 Plots saved:\n")
cat("   plot_xgb_cv_rmse.png              ← CV grid: max_depth × eta\n")
cat("   plot_xgb_actual_vs_pred.png       ← Model accuracy scatter\n")
cat("   plot_xgb_importance_builtin.png   ← xgb.plot.importance() (spec match)\n")
cat("   plot_xgb_importance.png           ← ggplot version for report\n")
cat("   plot_xgb_surge_heatmap.png        ← KEY SLIDE: zone × hour surge map\n")
cat("   plot_xgb_surge_heatmap_ev.png     ← EV vs Non-EV heatmap\n")

cat("\n📁 Data saved:\n")
cat("   trips_data_with_surge_pred.csv    ← Phase 5 incentive sim reads this\n")
cat("   xgb_model.bin                     ← Saved model\n")

cat("\n📌 Key results for your report:\n")
cat("   RMSE  =", round(rmse_xgb, 5), "\n")
cat("   R²    =", round(r2_xgb,   4), "\n")
cat("   Best max_depth =", best_depth, "| eta =", best_eta,
    "| nrounds =", best_nrounds, "\n")

cat("\n   Top 3 features driving surge:\n")
for (i in 1:min(3, nrow(importance_matrix))) {
  cat("  ", i, ".", importance_matrix$Feature[i],
      "→ Gain =", round(importance_matrix$Gain[i], 4), "\n")
}

cat("\n   Heatmap insight: check plot_xgb_surge_heatmap.png\n")
cat("   → Downtown + Airport during AM/PM peak = highest predicted surge\n")
cat("   → Suburbs at midnight = lowest predicted surge\n")

cat("\nRun phase5_incentive_simulation.R next!\n")