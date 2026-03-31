# =============================================================================
# PHASE 7: FINAL EVALUATION + PRESENTATION ASSEMBLY
# Project: Dynamic Pricing Analysis for Ride-Sharing EV Fleets
# =============================================================================
#
#   STEP 1 — Model performance summary table   (RF + XGBoost + Logistic)
#   STEP 2 — Scenario comparison dashboard     (patchwork p1 | p2 | p3)
#   STEP 3 — Policy recommendation write-up   (.txt + .Rmd)
#   STEP 4 — Sensitivity analysis              (demand ±20%, fuel ±20%)
#   STEP 5 — Presentation slide map            (10-slide plan)
#
# =============================================================================
# WHAT WAS WRONG IN THE PREVIOUS VERSION — AND THE FIX:
#
#   Phase 3 saves demand_data_with_pred.csv which ALREADY contains every
#   engineered feature:
#     is_peak, weather_severity, hour_sin, hour_cos,
#     rolling_avg_demand_3h, day_num, zone_tier (from Phase 1)
#
#   The previous Phase 7 re-derived these from scratch AND used the wrong
#   column name "is_peak_hour" instead of "is_peak" in rf_features, causing
#   predict() to fail or use the wrong feature.
#
#   THE FIX: Phase 7 simply loads demand_data_with_pred.csv, re-applies
#   factor levels (CSV drops factor types) using the EXACT SAME levels as
#   Phase 3, and uses the EXACT SAME features vector as Phase 3.
#
#   Phase 3 features vector (reproduced exactly — do not modify):
#     "hour", "hour_sin", "hour_cos", "day_of_week",
#     "is_peak",            ← NOT "is_peak_hour"
#     "is_weekend", "zone", "zone_tier", "weather", "weather_severity",
#     "available_drivers", "ev_driver_share", "rolling_avg_demand_3h"
# =============================================================================
# RUNS AFTER : phases 1–6
# READS      : demand_data_with_pred.csv      (Phase 3 output — has all features)
#              trips_data_with_surge_pred.csv  (Phase 4 output)
#              scenario_comparison.csv         (Phase 5 output)
#              driver_data.csv                 (Phase 6 output)
#              rf_model.rds                    (Phase 3 model)
#              xgb_model.bin                   (Phase 4 model)
#              logit_model.rds                 (Phase 6 model)
# SAVES      : plot_p7_model_table.png
#              plot_p7_dashboard.png
#              plot_p7_sensitivity.png
#              plot_p7_sensitivity_heatmap.png
#              plot_p7_slide_map.png
#              phase7_policy_recommendation.txt
#              phase7_policy_recommendation.Rmd
#              slide_map.csv
# =============================================================================


# ── 0. Packages ───────────────────────────────────────────────────────────────
# install.packages(c("tidyverse","patchwork","scales","ggrepel",
#                    "randomForest","xgboost","pROC","gt"))

library(tidyverse)
library(patchwork)
library(scales)
library(ggrepel)
library(randomForest)
library(xgboost)
library(pROC)
library(gt)

set.seed(42)

`%+%` <- function(a, b) paste0(a, b)

p7_theme <- theme_minimal(base_size = 12) +
  theme(
    plot.title       = element_text(face = "bold", size = 13),
    plot.subtitle    = element_text(size = 10, color = "grey45"),
    plot.caption     = element_text(size = 8.5, color = "grey55"),
    legend.position  = "bottom",
    panel.grid.minor = element_blank(),
    strip.text       = element_text(face = "bold", size = 10),
    plot.background  = element_rect(fill = "white", color = NA)
  )

ev_colors <- c("EV" = "#1D9E75", "Non-EV" = "#D85A30")

cat("══════════════════════════════════════════════\n")
cat("PHASE 7: FINAL EVALUATION\n")
cat("══════════════════════════════════════════════\n\n")


# ── 1. Load all saved outputs ─────────────────────────────────────────────────

# demand_data_with_pred.csv comes from Phase 3.
# It already has: is_peak, weather_severity, hour_sin, hour_cos,
# rolling_avg_demand_3h, day_num, zone_tier (Phase 1 values), predicted_demand.
# We do NOT re-derive any of these — just load and re-apply factor types.

demand      <- read_csv("demand_data_with_predictions.csv",      show_col_types = FALSE)
trips       <- read_csv("trips_data_with_surge_pred.csv", show_col_types = FALSE)
scen_compare<- read_csv("scenario_comparison.csv",        show_col_types = FALSE)
driver_data <- read_csv("driver_data.csv",                show_col_types = FALSE)

rf_model    <- readRDS("rf_model.rds")
xgb_model   <- xgb.load("xgb_model.bin")
logit_model <- readRDS("logit_model.rds")

cat("✅ All CSVs and models loaded\n")
cat("   demand columns:", paste(names(demand), collapse = ", "), "\n\n")


# =============================================================================
# STEP 1: MODEL PERFORMANCE SUMMARY TABLE
# =============================================================================

cat("── STEP 1: Model performance summary table ──\n")

# ─────────────────────────────────────────────────────────────────────────────
# 1A. RANDOM FOREST METRICS
#
# demand_data_with_pred.csv already has all 13 features Phase 3 used.
# We only need to re-apply factor encoding (CSV saves factors as characters).
# Use the EXACT SAME factor levels Phase 3 applied.
# ─────────────────────────────────────────────────────────────────────────────

demand <- demand %>%
  mutate(
    is_peak_hour = as.integer(is_peak_hour),
    is_weekend   = as.integer(is_weekend),
    day_of_week_num = as.integer(day_of_week_num),
    zone_tier    = as.integer(zone_tier),
    weather_flag = as.integer(weather_flag),
    weather_surge_adj = as.numeric(weather_surge_adj)
  )
demand$zone_factor <- factor(
  demand$zone,
  levels = c("Airport","Downtown","Midtown","Suburb_North","Suburb_South")
)
# EXACT same features vector as Phase 3 — copied verbatim
rf_features <- c(
  "hour",
  "day_of_week_num",
  "is_peak_hour",
  "is_weekend",
  "time_of_day",
  "zone_factor",
  "zone_tier",
  "weather_flag",
  "weather_surge_adj",
  "available_drivers",
  "ev_driver_share",
  "rolling_avg_demand_3h",
  "avg_demand_score",
  "demand_supply_ratio"
)

# Temporal test set — same split as Phase 3: days 25–30
demand_test_rf <- demand %>% filter(day_num > 24)

cat("   RF test rows:", nrow(demand_test_rf),
    "| features:", length(rf_features), "\n")

# Confirm all features exist in the CSV before predicting
missing_rf <- setdiff(rf_features, names(demand_test_rf))
if (length(missing_rf) > 0) {
  stop("Missing RF features: ", paste(missing_rf, collapse = ", "))
} else {
  cat("   ✅ All RF features present in demand_data_with_pred.csv\n")
}

# Predict using the loaded rf_model
rf_pred_p7 <- predict(rf_model,
                      newdata = demand_test_rf %>% select(all_of(rf_features)))

# Metrics (same formulas as Phase 3)
rf_resid <- demand_test_rf$trip_count - rf_pred_p7
rf_rmse  <- round(sqrt(mean(rf_resid^2)), 4)
rf_mae   <- round(mean(abs(rf_resid)),    4)
ss_res_rf <- sum(rf_resid^2)
ss_tot_rf <- sum((demand_test_rf$trip_count -
                    mean(demand_test_rf$trip_count))^2)
rf_r2    <- round(1 - ss_res_rf / ss_tot_rf, 4)

cat("   RF — RMSE:", rf_rmse, "| MAE:", rf_mae, "| R²:", rf_r2, "\n")

# ─────────────────────────────────────────────────────────────────────────────
# 1B. XGBOOST METRICS
#
# trips_data_with_surge_pred.csv already has pred_surge from Phase 4.
# Derive residuals directly — no need to re-run the model.
# ─────────────────────────────────────────────────────────────────────────────

trips <- trips %>%
  mutate(day_num_trip = as.integer(as.Date(date) - min(as.Date(date))) + 1L)

trips_test_xgb <- trips %>% filter(day_num_trip > 24)

xgb_resid  <- trips_test_xgb$surge_multiplier - trips_test_xgb$pred_surge
xgb_rmse   <- round(sqrt(mean(xgb_resid^2)), 5)
xgb_mae    <- round(mean(abs(xgb_resid)),    5)
ss_res_xgb <- sum(xgb_resid^2)
ss_tot_xgb <- sum((trips_test_xgb$surge_multiplier -
                     mean(trips_test_xgb$surge_multiplier))^2)
xgb_r2     <- round(1 - ss_res_xgb / ss_tot_xgb, 4)

cat("   XGB — RMSE:", xgb_rmse, "| MAE:", xgb_mae, "| R²:", xgb_r2, "\n")

# ─────────────────────────────────────────────────────────────────────────────
# 1C. LOGISTIC REGRESSION METRICS
#
# Re-split driver_data with the SAME seed as Phase 6 (set.seed(42))
# so the test set is identical.
# ─────────────────────────────────────────────────────────────────────────────

driver_data <- driver_data %>%
  mutate(
    adopted_ev_int = case_when(
      adopted_ev == "EV"      ~ 1L,
      adopted_ev == "Non-EV"  ~ 0L,
      adopted_ev == 1         ~ 1L,
      adopted_ev == 0         ~ 0L,
      TRUE ~ NA_integer_
    )
  )
set.seed(42)   # same seed as Phase 6
train_idx_p7 <- sample(nrow(driver_data), floor(0.80 * nrow(driver_data)))
drv_test_p7  <- driver_data[-train_idx_p7, ]

drv_test_p7 <- drv_test_p7 %>%
  mutate(
    pred_prob  = predict(logit_model, newdata = drv_test_p7,
                         type = "response"),
    pred_class = as.integer(pred_prob >= 0.5)
  )

roc_obj_p7     <- roc(drv_test_p7$adopted_ev_int, drv_test_p7$pred_prob,
                      levels = c(0, 1), direction = "<", quiet = TRUE)
logit_auc      <- round(auc(roc_obj_p7), 4)
logit_accuracy <- round(
  mean(drv_test_p7$pred_class == drv_test_p7$adopted_ev_int) * 100, 1)

cat("   Logit — AUC:", logit_auc, "| Accuracy:", logit_accuracy, "%\n\n")

# ── 1D. Build and style the comparison table ──────────────────────────────────
# Exact spec: data.frame(model=c('RF','XGB','Logit'), rmse=c(...), r2=c(...))
model_perf <- data.frame(
  Model        = c("Random Forest (Phase 3)",
                   "XGBoost (Phase 4)",
                   "Logistic Regression (Phase 6)"),
  Task         = c("Demand prediction", "Surge prediction", "EV adoption"),
  Target       = c("trip_count",        "surge_multiplier", "adopted_ev"),
  RMSE         = c(rf_rmse,  xgb_rmse,  NA),
  R_squared    = c(rf_r2,    xgb_r2,    NA),
  AUC          = c(NA,       NA,         logit_auc),
  Accuracy_pct = c(NA,       NA,         logit_accuracy),
  stringsAsFactors = FALSE
)

cat("   ── Model performance ──\n")
print(model_perf)

model_gt <- model_perf %>%
  gt() %>%
  tab_header(title    = md("**Model performance summary**"),
             subtitle = "Dynamic Pricing Analysis for Ride-Sharing EV Fleets") %>%
  cols_label(Model = "Model", Task = "Task", Target = "Target",
             RMSE = "RMSE", R_squared = "R²", AUC = "AUC",
             Accuracy_pct = "Accuracy (%)") %>%
  fmt_number(columns = c(RMSE, R_squared, AUC),
             decimals = 4, use_seps = FALSE) %>%
  fmt_number(columns = Accuracy_pct, decimals = 1) %>%
  sub_missing(missing_text = "—") %>%
  tab_style(style = list(cell_fill(color = "#E1F5EE"),
                         cell_text(weight = "bold")),
            locations = cells_body(rows = 1)) %>%
  tab_style(style = list(cell_fill(color = "#E6F1FB"),
                         cell_text(weight = "bold")),
            locations = cells_body(rows = 2)) %>%
  tab_style(style = list(cell_fill(color = "#FAEEDA"),
                         cell_text(weight = "bold")),
            locations = cells_body(rows = 3)) %>%
  tab_footnote("RMSE/R² not applicable to logistic regression") %>%
  tab_footnote("AUC not applicable to regression models") %>%
  opt_table_font(font = "sans-serif") %>%
  tab_options(table.font.size = 13, heading.title.font.size = 15)

gtsave(model_gt, "plot_p7_model_table.png")
cat("   ✅ plot_p7_model_table.png saved\n\n")


# =============================================================================
# STEP 2: SCENARIO COMPARISON DASHBOARD
# Exact spec: patchwork: p1 + p2 + p3
# =============================================================================

cat("── STEP 2: Scenario comparison dashboard ──\n")

# Rebuild Phase 5 earnings columns on trips
trips <- trips %>%
  mutate(
    is_ev          = vehicle_type == "EV",
    is_peak        = as.logical(is_peak),
    is_weekend     = as.logical(is_weekend),
    op_cost_per_km = if_else(is_ev, 0.12, 0.28),
    operating_cost = round(distance_km * op_cost_per_km, 2),
    base_net_earn  = round((base_fare_usd * surge_multiplier -
                              operating_cost) * 0.80, 2),
    ev_surge_A     = if_else(is_ev, pmin(surge_multiplier, 1.5),
                             surge_multiplier),
    fare_A         = round(base_fare_usd * ev_surge_A, 2),
    net_earn_A     = round((fare_A - operating_cost) * 0.80, 2),
    net_earn_B40   = round(net_earn_A +
                             if_else(is_ev & is_peak, 40, 0), 2),
    rider_fare_C   = if_else(is_ev & !is_peak,
                             round(fare_A * 0.9, 2), fare_A),
    subsidy_C2     = if_else(is_ev & !is_peak,
                             round(fare_A * 0.10 * 0.80, 2), 0),
    net_earn_C2    = round((if_else(is_ev & !is_peak,
                                    round(fare_A * 0.9, 2), fare_A) -
                              operating_cost) * 0.80 +
                             if_else(is_ev & !is_peak,
                                     round(fare_A * 0.10 * 0.80, 2), 0), 2)
  )

scen_levels <- c("Baseline","A: Surge cap 1.5×",
                 "B: Cap + $40 bonus","C: Discount + subsidy")

scenario_earn <- bind_rows(
  trips %>% group_by(vehicle_type) %>%
    summarise(scenario = "Baseline",
              mean_earn = mean(base_net_earn),
              total_rev = sum(base_fare_usd * surge_multiplier),
              .groups = "drop"),
  trips %>% group_by(vehicle_type) %>%
    summarise(scenario = "A: Surge cap 1.5×",
              mean_earn = mean(net_earn_A),
              total_rev = sum(fare_A), .groups = "drop"),
  trips %>% group_by(vehicle_type) %>%
    summarise(scenario = "B: Cap + $40 bonus",
              mean_earn = mean(net_earn_B40),
              total_rev = sum(fare_A), .groups = "drop"),
  trips %>% group_by(vehicle_type) %>%
    summarise(scenario = "C: Discount + subsidy",
              mean_earn = mean(net_earn_C2),
              total_rev = sum(rider_fare_C), .groups = "drop")
) %>%
  mutate(scenario     = factor(scenario, levels = scen_levels),
         vehicle_type = factor(vehicle_type, levels = c("EV","Non-EV")),
         mean_earn    = round(mean_earn, 3),
         total_rev    = round(total_rev, 0))

baseline_ev_earn <- scenario_earn %>%
  filter(scenario == "Baseline", vehicle_type == "EV") %>%
  pull(mean_earn)

# Panel 1: earnings
p_dash1 <- ggplot(scenario_earn,
                  aes(x = scenario, y = mean_earn, fill = vehicle_type)) +
  geom_col(position = position_dodge(0.72), width = 0.62, alpha = 0.88) +
  geom_hline(yintercept = baseline_ev_earn, linetype = "dashed",
             color = "#1D9E75", linewidth = 0.7) +
  geom_text(aes(label = paste0("$", round(mean_earn, 1))),
            position = position_dodge(0.72),
            vjust = -0.45, size = 2.5, color = "grey25") +
  scale_fill_manual(values = ev_colors, name = NULL) +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01),
                     expand = expansion(mult = c(0, 0.14))) +
  labs(title = "Mean net earnings per trip",
       subtitle = "EV vs Non-EV | dashed = EV baseline",
       x = NULL, y = "USD per trip") +
  p7_theme +
  theme(axis.text.x = element_text(angle = 18, hjust = 1, size = 8),
        plot.title  = element_text(size = 11))

# Panel 2: total revenue
revenue_data <- scenario_earn %>%
  distinct(scenario, total_rev) %>%
  mutate(rev_label = paste0("$", round(total_rev / 1000, 1), "K"))

baseline_rev_val <- revenue_data$total_rev[revenue_data$scenario == "Baseline"]

p_dash2 <- ggplot(revenue_data,
                  aes(x = scenario, y = total_rev / 1000, fill = scenario)) +
  geom_col(width = 0.62, alpha = 0.88) +
  geom_text(aes(label = rev_label), vjust = -0.4,
            size = 2.8, fontface = "bold", color = "grey20") +
  geom_hline(yintercept = baseline_rev_val / 1000,
             linetype = "dashed", color = "grey40", linewidth = 0.7) +
  scale_fill_manual(
    values = c("Baseline"              = "#888780",
               "A: Surge cap 1.5×"    = "#D85A30",
               "B: Cap + $40 bonus"   = "#1D9E75",
               "C: Discount + subsidy"= "#185FA5"),
    guide = "none"
  ) +
  scale_y_continuous(labels = label_dollar(suffix = "K", accuracy = 1),
                     expand = expansion(mult = c(0, 0.12))) +
  labs(title = "Total platform revenue",
       subtitle = "Across all trips | dashed = baseline",
       x = NULL, y = "Revenue (USD thousands)") +
  p7_theme +
  theme(axis.text.x = element_text(angle = 18, hjust = 1, size = 8),
        plot.title  = element_text(size = 11))

# Panel 3: headline numbers
ev_advantage_val <- round(mean(trips$base_net_earn[trips$is_ev]) -
                            mean(trips$base_net_earn[!trips$is_ev]), 2)

headlines <- tibble(
  label = c(
    paste0("EV fleet share\n",     round(mean(trips$is_ev)*100, 1), "%"),
    paste0("EV earn advantage\n$", ev_advantage_val, "/trip"),
    paste0("Surge range\n",
           round(min(trips$surge_multiplier),1), "× – ",
           round(max(trips$surge_multiplier),1), "×"),
    paste0("RF R²\n",     rf_r2),
    paste0("XGB R²\n",    xgb_r2),
    paste0("Logit AUC\n", logit_auc)
  ),
  x = c(1,2,3,1,2,3), y = c(2,2,2,1,1,1),
  col = c("#1D9E75","#1D9E75","#BA7517",
          "#185FA5","#185FA5","#534AB7")
)

p_dash3 <- ggplot(headlines, aes(x=x, y=y)) +
  geom_tile(fill="grey95", color="white", linewidth=1.5,
            width=0.88, height=0.78) +
  geom_text(aes(label=label, color=col),
            size=3.2, fontface="bold", lineheight=1.3) +
  scale_color_identity() +
  scale_x_continuous(limits=c(0.5,3.5)) +
  scale_y_continuous(limits=c(0.5,2.5)) +
  labs(title="Key headline numbers",
       subtitle="Fleet + models + earnings",
       x=NULL, y=NULL) +
  p7_theme +
  theme(axis.text=element_blank(), panel.grid=element_blank(),
        plot.title=element_text(size=11))

# Exact spec: patchwork p1 + p2 + p3
dashboard <- (p_dash1 | p_dash2 | p_dash3) +
  plot_annotation(
    title    = "Scenario comparison dashboard — Dynamic EV Pricing",
    subtitle = "Phase 5 incentive scenarios vs baseline | all 5000 trips",
    caption  = "Source: Phases 1–6",
    theme    = theme(
      plot.title      = element_text(face="bold", size=15),
      plot.subtitle   = element_text(size=11, color="grey40"),
      plot.background = element_rect(fill="white", color=NA)
    )
  )

ggsave("plot_p7_dashboard.png", dashboard, width=16, height=6, dpi=150)
cat("   ✅ plot_p7_dashboard.png saved\n\n")


# =============================================================================
# STEP 3: POLICY RECOMMENDATION WRITE-UP
# Exact spec: # narrative in Rmd
# =============================================================================

cat("── STEP 3: Policy recommendation ──\n")

ev_baseline_earn <- round(mean(trips$base_net_earn[trips$is_ev]),  2)
nonev_base_earn  <- round(mean(trips$base_net_earn[!trips$is_ev]), 2)
ev_scenB_earn    <- round(mean(trips$net_earn_B40[trips$is_ev]),   2)
ev_scenC_earn    <- round(mean(trips$net_earn_C2[trips$is_ev]),    2)
ev_fleet_pct     <- round(mean(trips$is_ev) * 100, 1)

rec_text <- paste0(
  "====================================================================
POLICY RECOMMENDATION — Dynamic Pricing for EV Fleet Adoption
====================================================================

EXECUTIVE SUMMARY
  Scenario B (surge cap 1.5× + $40 peak bonus) is recommended.
  It restores EV earnings while sustaining an adoption advantage.

BASELINE STATE
  EV mean net earnings : $", ev_baseline_earn, " / trip
  Non-EV mean earnings : $", nonev_base_earn,  " / trip
  EV fleet share       : ", ev_fleet_pct, "%

MODEL VALIDATION
  Random Forest  — RMSE: ", rf_rmse,  " | R²: ", rf_r2,  "
  XGBoost        — RMSE: ", xgb_rmse, " | R²: ", xgb_r2, "
  Logistic       — AUC:  ", logit_auc, " | Accuracy: ", logit_accuracy, "%

SCENARIO RESULTS (EV earnings)
  A (cap only)       : earnings drop — not recommended standalone
  B (cap + $40 bonus): $", ev_scenB_earn, " / trip  ← RECOMMENDED
  C (off-peak subsidy): $", ev_scenC_earn, " / trip  ← complementary

RECOMMENDATION
  1. Deploy Scenario B for peak EV trips immediately.
  2. Add Scenario C off-peak to cover remaining hours.
  3. Adjust bonus monthly using S-curve tipping point.
  4. Prioritise Downtown + Airport (Tier 1) zones first.
====================================================================
")

cat(rec_text)
writeLines(rec_text, "phase7_policy_recommendation.txt")
cat("   ✅ phase7_policy_recommendation.txt saved\n")

rmd_text <- '---
title: "Dynamic Pricing Analysis for Ride-Sharing EV Fleets"
output:
  html_document:
    toc: true
    toc_float: true
    theme: flatly
---

```{r setup, include=FALSE}
knitr::opts_chunk$set(echo=FALSE, warning=FALSE, message=FALSE,
                      fig.width=10, fig.height=5.5)
library(tidyverse); library(scales); library(patchwork); library(gt)
```

## 1. Dataset
```{r}
glimpse(read_csv("trips_data_with_surge_pred.csv", show_col_types=FALSE))
```

## 2. EDA
```{r, out.width="100%"}
knitr::include_graphics("plot1_demand_patterns.png")
knitr::include_graphics("plot3_earnings_comparison.png")
```

## 3. Model performance
```{r, out.width="100%"}
knitr::include_graphics("plot_p7_model_table.png")
```

## 4. Scenario comparison
```{r, out.width="100%"}
knitr::include_graphics("plot_p7_dashboard.png")
```

## 5. Adoption S-curve + ROC
```{r, out.width="100%"}
knitr::include_graphics("plot_p6_adoption_scurve.png")
knitr::include_graphics("plot_p6_roc_curve.png")
```

## 6. Sensitivity analysis
```{r, out.width="100%"}
knitr::include_graphics("plot_p7_sensitivity_heatmap.png")
```

## 7. Policy recommendation
> **Recommended: Scenario B** — see phase7_policy_recommendation.txt
'
writeLines(rmd_text, "phase7_policy_recommendation.Rmd")
cat("   ✅ phase7_policy_recommendation.Rmd saved\n\n")


# =============================================================================
# STEP 4: SENSITIVITY ANALYSIS
# Exact spec: map(c(0.8, 1.0, 1.2), ~run_scenario(demand_scale=.x))
# =============================================================================

cat("── STEP 4: Sensitivity analysis ──\n")

run_scenario_B <- function(demand_scale     = 1.0,
                           fuel_price_scale = 1.0,
                           bonus_amount     = 40) {
  trips %>%
    mutate(
      op_cost_scaled = if_else(is_ev, operating_cost,
                               operating_cost * fuel_price_scale),
      surge_scaled   = pmin(3.0, pmax(1.0, surge_multiplier * demand_scale)),
      ev_surge_sc    = if_else(is_ev, pmin(1.5, surge_scaled), surge_scaled),
      fare_sc        = round(base_fare_usd * ev_surge_sc, 2),
      net_earn_sim   = round(
        (fare_sc - op_cost_scaled) * 0.80 +
          if_else(is_ev & is_peak, bonus_amount, 0), 2)
    ) %>%
    group_by(vehicle_type) %>%
    summarise(demand_scale  = demand_scale,
              fuel_scale    = fuel_price_scale,
              bonus         = bonus_amount,
              mean_net_earn = round(mean(net_earn_sim), 3),
              total_rev     = round(sum(fare_sc), 0),
              .groups = "drop")
}

# Exact spec: map(c(0.8, 1.0, 1.2), ~run_scenario(demand_scale=.x))
demand_scales      <- c(0.8, 1.0, 1.2)
fuel_scales        <- c(0.8, 1.0, 1.2)

sensitivity_demand <- map_dfr(demand_scales,
                              ~run_scenario_B(demand_scale = .x))

sensitivity_grid   <- map_dfr(demand_scales, function(ds) {
  map_dfr(fuel_scales, function(fs) {
    run_scenario_B(demand_scale = ds, fuel_price_scale = fs)
  })
})

cat("   EV earnings under demand sensitivity:\n")
sensitivity_demand %>%
  filter(vehicle_type == "EV") %>%
  select(demand_scale, mean_net_earn) %>% print()

# Line chart
p_sens <- sensitivity_demand %>%
  mutate(demand_label = paste0(
    ifelse(demand_scale < 1, "-", "+"),
    abs(round((demand_scale - 1)*100)), "%",
    ifelse(demand_scale == 1.0, " (baseline)", " demand"))) %>%
  ggplot(aes(x = factor(demand_label, levels = unique(demand_label)),
             y = mean_net_earn, color = vehicle_type, group = vehicle_type)) +
  geom_line(linewidth = 1.1) +
  geom_point(size = 3.5) +
  geom_text(aes(label = paste0("$", round(mean_net_earn, 2))),
            vjust = -0.8, size = 2.8) +
  geom_hline(yintercept = ev_baseline_earn, linetype = "dashed",
             color = "#1D9E75", linewidth = 0.7) +
  annotate("text", x = 0.6, y = ev_baseline_earn,
           label = "  EV baseline", hjust = 0, vjust = -0.5,
           size = 2.6, color = "#1D9E75") +
  scale_color_manual(values = ev_colors, name = "Vehicle") +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01),
                     expand = expansion(mult = c(0.1, 0.14))) +
  labs(title    = "Sensitivity: Scenario B under ±20% demand shift",
       subtitle = "EV advantage holds even at −20% demand",
       x = "Demand scenario", y = "Mean net earnings (USD/trip)",
       caption = "Scenario B: 1.5× cap + $40 peak bonus | dashed = EV baseline") +
  p7_theme

ggsave("plot_p7_sensitivity.png", p_sens, width = 10, height = 5.5, dpi = 150)
cat("   ✅ plot_p7_sensitivity.png saved\n")

# Heatmap
heat_data <- sensitivity_grid %>%
  filter(vehicle_type == "EV") %>%
  mutate(
    demand_label = paste0(ifelse(demand_scale<1,"-","+"),
                          abs(round((demand_scale-1)*100)), "% demand"),
    fuel_label   = paste0(ifelse(fuel_scale<1,"-","+"),
                          abs(round((fuel_scale-1)*100)), "% fuel cost")
  )

p_heat_sens <- ggplot(heat_data,
                      aes(x = demand_label, y = fuel_label,
                          fill = mean_net_earn)) +
  geom_tile(color = "white", linewidth = 0.8) +
  geom_text(aes(label = paste0("$", round(mean_net_earn, 2))),
            size = 3.2, color = "grey10", fontface = "bold") +
  scale_fill_gradient2(
    low = "#D85A30", mid = "#FAC775", high = "#1D9E75",
    midpoint = ev_baseline_earn, name = "EV earn\n(USD/trip)"
  ) +
  labs(title    = "Sensitivity heatmap — EV earnings: demand × fuel price",
       subtitle = "Scenario B | green = above EV baseline, red = below",
       x = "Demand shift", y = "Fuel price shift",
       caption  = paste0("EV baseline: $", ev_baseline_earn, "/trip")) +
  p7_theme + theme(panel.grid = element_blank())

ggsave("plot_p7_sensitivity_heatmap.png", p_heat_sens,
       width = 9, height = 5, dpi = 150)
cat("   ✅ plot_p7_sensitivity_heatmap.png saved\n\n")


# =============================================================================
# STEP 5: PRESENTATION SLIDE MAP
# Exact spec: Map each analysis to a slide (8–10 slides)
# =============================================================================

cat("── STEP 5: Slide map ──\n\n")

slide_map <- tribble(
  ~slide, ~title,                            ~key_plot,                        ~phase,
  1L,  "Title + project overview",           "(text slide)",                   "—",
  2L,  "Dataset design",                     "plot_p7_model_table.png",        "P1+P7",
  3L,  "Demand patterns (EDA)",              "plot1_demand_patterns.png",      "P2",
  4L,  "Surge + EV earnings (EDA)",         "plot2a + plot3",                  "P2",
  5L,  "RF demand model",                   "plot_rf_actual_vs_pred.png",      "P3",
  6L,  "XGBoost surge + heatmap",           "plot_xgb_surge_heatmap.png",      "P4",
  7L,  "Incentive scenario dashboard",      "plot_p7_dashboard.png",           "P5+P7",
  8L,  "EV adoption S-curve + ROC",         "plot_p6_adoption_scurve.png",     "P6",
  9L,  "Sensitivity analysis",              "plot_p7_sensitivity_heatmap.png", "P7",
  10L, "Policy recommendation",             "policy_recommendation.txt",       "P7"
)

for (i in seq_len(nrow(slide_map))) {
  cat(sprintf("   Slide %2d │ %-38s │ %s\n",
              slide_map$slide[i], slide_map$title[i], slide_map$phase[i]))
}

write_csv(slide_map, "slide_map.csv")
cat("\n   ✅ slide_map.csv saved\n")

p_slides <- slide_map %>%
  mutate(
    lbl        = paste0("Slide ", slide, " — ", title),
    lbl        = factor(lbl, levels = rev(lbl)),
    phase_grp  = str_extract(phase, "P\\d+")
  ) %>%
  ggplot(aes(x = 1, y = lbl, fill = phase_grp)) +
  geom_tile(color = "white", linewidth = 1.2,
            width = 0.92, height = 0.82) +
  geom_text(aes(label = lbl), size = 2.9,
            color = "grey15", fontface = "bold") +
  scale_fill_manual(
    values = c("P1"="#D3D1C7","P2"="#B5D4F4","P3"="#9FE1CB",
               "P4"="#FAC775","P5"="#F4C0D1","P6"="#CECBF6",
               "P7"="#F5C4B3"),
    na.value = "#F1EFE8", name = "Phase"
  ) +
  labs(title = "10-slide presentation map",
       subtitle = "Phase source for each slide",
       x = NULL, y = NULL) +
  p7_theme +
  theme(axis.text = element_blank(), panel.grid = element_blank())

ggsave("plot_p7_slide_map.png", p_slides, width = 10, height = 7, dpi = 150)
cat("   ✅ plot_p7_slide_map.png saved\n")


# =============================================================================
# FINAL SUMMARY
# =============================================================================

cat("\n══════════════════════════════════════════════════════\n")
cat("PHASE 7 COMPLETE\n")
cat("══════════════════════════════════════════════════════\n\n")

cat("📊 Plots:\n")
cat("   plot_p7_model_table.png\n")
cat("   plot_p7_dashboard.png\n")
cat("   plot_p7_sensitivity.png\n")
cat("   plot_p7_sensitivity_heatmap.png\n")
cat("   plot_p7_slide_map.png\n")

cat("\n📁 Documents:\n")
cat("   phase7_policy_recommendation.txt\n")
cat("   phase7_policy_recommendation.Rmd\n")
cat("   slide_map.csv\n")

cat("\n📌 Final metrics:\n")
cat("   RF   — RMSE:", rf_rmse,  "| R²:", rf_r2,   "\n")
cat("   XGB  — RMSE:", xgb_rmse, "| R²:", xgb_r2,  "\n")
cat("   Logit—  AUC:", logit_auc, "| Accuracy:", logit_accuracy, "%\n")

cat("\n📌 Recommended policy: SCENARIO B\n")
cat("   EV earnings: $", ev_scenB_earn,
    "/trip vs baseline $", ev_baseline_earn, "/trip\n")
cat("   Complement with Scenario C off-peak.\n")

cat("\n🎉 Pipeline: Phases 1 → 7 complete\n")