# =============================================================================
# PHASE 5: INCENTIVE SIMULATION
# Project: Dynamic Pricing Analysis for Ride-Sharing EV Fleets
# =============================================================================
# This script simulates 3 alternative pricing/incentive policies and compares
# them against the current baseline to find the best scenario for EV adoption
# without hurting driver income.
#
#   STEP 1 — Baseline    : current state — same surge for EV and Non-EV
#   STEP 2 — Scenario A  : surge cap for EVs at 1.5×
#   STEP 3 — Scenario B  : flat peak-hour bonus for EVs (₹20 / ₹40 / ₹60)
#   STEP 4 — Scenario C  : 10% rider discount for EVs off-peak + platform subsidy
#   STEP 5 — Compare all : summary table + plots + Pareto analysis
#
# =============================================================================
# RUNS AFTER : phase4_xgboost.R
# READS      : trips_data_with_surge_pred.csv
# SAVES      : scenario_comparison.csv
#              plot_p5_baseline.png
#              plot_p5_scenario_A.png
#              plot_p5_scenario_B.png
#              plot_p5_scenario_C.png
#              plot_p5_comparison_table.png
#              plot_p5_pareto.png
#              plot_p5_earnings_bump.png
# =============================================================================


# ── 0. Packages ───────────────────────────────────────────────────────────────
# install.packages(c("tidyverse", "scales", "ggrepel", "kableExtra"))

library(tidyverse)
library(scales)
library(ggrepel)

set.seed(42)


# ── 1. Load data ──────────────────────────────────────────────────────────────
# Phase 4 saved trips with: trip_id, date, hour, zone, vehicle_type,
# surge_multiplier, pred_surge, predicted_demand, distance_km,
# base_fare_usd, final_fare_usd, driver_net_usd, is_peak, is_weekend, weather

trips <- read_csv("trips_data_with_surge_pred.csv", show_col_types = FALSE)

cat("✅ trips loaded —", nrow(trips), "rows,", ncol(trips), "columns\n")
cat("   Columns:", paste(names(trips), collapse = ", "), "\n\n")

# ── Type cleanup ──────────────────────────────────────────────────────────────
trips <- trips %>%
  mutate(
    vehicle_type = factor(vehicle_type, levels = c("EV", "Non-EV")),
    zone         = factor(zone),
    is_ev        = vehicle_type == "EV",          # logical helper
    is_peak      = as.logical(is_peak),
    is_weekend   = as.logical(is_weekend),
    
    # Platform commission rate
    commission_rate = 0.20,
    
    # Re-derive operating cost per trip from Phase 1 logic
    # EV = $0.12/km, Non-EV = $0.28/km
    op_cost_per_km = if_else(is_ev, 0.12, 0.28),
    operating_cost = round(distance_km * op_cost_per_km, 2)
  )

# ── Shared theme ──────────────────────────────────────────────────────────────
p5_theme <- theme_minimal(base_size = 12) +
  theme(
    plot.title       = element_text(face = "bold", size = 14),
    plot.subtitle    = element_text(size = 11, color = "grey45"),
    plot.caption     = element_text(size = 9,  color = "grey55"),
    legend.position  = "bottom",
    panel.grid.minor = element_blank(),
    strip.text       = element_text(face = "bold"),
    plot.background  = element_rect(fill = "white", color = NA)
  )

ev_colors <- c("EV" = "#1D9E75", "Non-EV" = "#D85A30")

cat("── Setup complete. Starting simulations... ──\n\n")


# =============================================================================
# STEP 1: BASELINE
# =============================================================================
# Current state: EV and Non-EV get IDENTICAL surge multipliers.
# We compute per-trip earnings using the actual surge_multiplier from Phase 1.
#
# Earnings formula (same as Phase 1):
#   final_fare    = base_fare_usd × surge_multiplier
#   gross_earn    = final_fare − operating_cost
#   net_earn      = gross_earn × (1 − commission_rate)   [20% platform cut]
# =============================================================================

cat("── STEP 1: Baseline ──\n")

trips <- trips %>%
  mutate(
    # Recalculate cleanly from base components (Phase 1 formula)
    base_final_fare = round(base_fare_usd * surge_multiplier, 2),
    base_gross_earn = round(base_final_fare - operating_cost, 2),
    base_net_earn   = round(base_gross_earn * (1 - commission_rate), 2)
  )

# Exact spec: baseline <- trips %>% group_by(vehicle_type) %>%
#               summarise(mean_earn = mean(earnings))
baseline_summary <- trips %>%
  group_by(vehicle_type) %>%
  summarise(
    mean_net_earn   = round(mean(base_net_earn),   3),
    median_net_earn = round(median(base_net_earn), 3),
    total_revenue   = round(sum(base_final_fare),  2),
    n_trips         = n(),
    fleet_share_pct = round(n() / nrow(trips) * 100, 1),
    .groups = "drop"
  )

# Per-zone baseline
baseline_zone <- trips %>%
  group_by(zone, vehicle_type) %>%
  summarise(
    mean_net_earn = round(mean(base_net_earn),  3),
    surge_revenue = round(sum(base_final_fare - base_fare_usd), 2),
    .groups = "drop"
  )

cat("   Baseline summary:\n")
print(baseline_summary)

# Plot: Baseline earnings by zone
p_base <- ggplot(baseline_zone,
                 aes(x = zone, y = mean_net_earn, fill = vehicle_type)) +
  geom_col(position = position_dodge(0.75), width = 0.65, alpha = 0.88) +
  scale_fill_manual(values = ev_colors, name = "Vehicle") +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01)) +
  labs(
    title    = "Baseline: mean net earnings per trip — EV vs Non-EV",
    subtitle = "Current pricing — same surge multiplier for both vehicle types",
    x        = "Zone", y = "Mean net earnings (USD)",
    caption  = "Baseline: no incentive modifications applied"
  ) + p5_theme +
  theme(axis.text.x = element_text(angle = 25, hjust = 1))

ggsave("plot_p5_baseline.png", p_base, width = 10, height = 5, dpi = 150)
cat("   ✅ plot_p5_baseline.png saved\n\n")


# =============================================================================
# STEP 2: SCENARIO A — SURGE CAP FOR EVs
# =============================================================================
# Policy: EVs have surge capped at 1.5× (max) while Non-EVs keep up to 3.0×.
# Rationale: encourages riders to prefer EVs during busy periods (lower fare),
# but risk is EV drivers earn less during high-surge events.
#
# Question: Does EV income stay competitive after the cap?
# =============================================================================

cat("── STEP 2: Scenario A — Surge cap at 1.5× for EVs ──\n")

# Exact spec: trips$ev_surge_A <- pmin(trips$surge_multiplier, 1.5)
trips <- trips %>%
  mutate(
    ev_surge_A = if_else(
      is_ev,
      pmin(surge_multiplier, 1.5),   # EV: cap at 1.5×
      surge_multiplier               # Non-EV: unchanged
    ),
    fare_A      = round(base_fare_usd * ev_surge_A, 2),
    gross_earn_A= round(fare_A - operating_cost, 2),
    net_earn_A  = round(gross_earn_A * (1 - commission_rate), 2)
  )

scen_A_summary <- trips %>%
  group_by(vehicle_type) %>%
  summarise(
    scenario        = "A: Surge cap 1.5×",
    mean_net_earn   = round(mean(net_earn_A),   3),
    median_net_earn = round(median(net_earn_A), 3),
    total_revenue   = round(sum(fare_A),        2),
    n_trips         = n(),
    fleet_share_pct = round(n() / nrow(trips) * 100, 1),
    .groups = "drop"
  )

# How many EV trips were capped?
capped <- sum(trips$is_ev & trips$surge_multiplier > 1.5)
pct_capped <- round(capped / sum(trips$is_ev) * 100, 1)
cat("   EV trips where surge was capped:", capped, "(", pct_capped, "%)\n")

# Earnings change vs baseline
ev_earn_change_A <- scen_A_summary$mean_net_earn[scen_A_summary$vehicle_type == "EV"] -
  baseline_summary$mean_net_earn[baseline_summary$vehicle_type == "EV"]
cat("   EV mean earnings change vs baseline: $", round(ev_earn_change_A, 3), "\n")

# Plot: distribution of EV earnings — baseline vs capped
trips_long_A <- trips %>%
  filter(is_ev) %>%
  select(trip_id, base_net_earn, net_earn_A) %>%
  pivot_longer(cols = c(base_net_earn, net_earn_A),
               names_to  = "scenario",
               values_to = "net_earn") %>%
  mutate(scenario = if_else(scenario == "base_net_earn",
                            "Baseline (no cap)", "Scenario A (1.5× cap)"))

p_A <- ggplot(trips_long_A, aes(x = net_earn, fill = scenario)) +
  geom_histogram(aes(y = after_stat(density)), binwidth = 0.5,
                 alpha = 0.65, position = "identity",
                 color = "white", linewidth = 0.2) +
  geom_density(aes(color = scenario), linewidth = 0.9, fill = NA) +
  geom_vline(
    data = trips_long_A %>%
      group_by(scenario) %>%
      summarise(m = mean(net_earn), .groups = "drop"),
    aes(xintercept = m, color = scenario),
    linetype = "dashed", linewidth = 0.8
  ) +
  scale_fill_manual(values  = c("Baseline (no cap)" = "#185FA5",
                                "Scenario A (1.5× cap)" = "#D85A30"),
                    name = NULL) +
  scale_color_manual(values = c("Baseline (no cap)" = "#185FA5",
                                "Scenario A (1.5× cap)" = "#D85A30"),
                     name = NULL) +
  scale_x_continuous(labels = label_dollar(accuracy = 0.01)) +
  annotate("text", x = Inf, y = Inf,
           label = paste0("Earnings change: $", round(ev_earn_change_A, 2),
                          "\n", pct_capped, "% of EV trips capped"),
           hjust = 1.1, vjust = 1.4, size = 3, color = "grey25") +
  labs(
    title    = "Scenario A: EV surge capped at 1.5× — earnings distribution",
    subtitle = "EV-only view | dashed lines = mean earnings per scenario",
    x        = "Net earnings per trip (USD)", y = "Density",
    caption  = "Non-EV earnings unchanged under Scenario A"
  ) + p5_theme

ggsave("plot_p5_scenario_A.png", p_A, width = 10, height = 5.5, dpi = 150)
cat("   ✅ plot_p5_scenario_A.png saved\n\n")


# =============================================================================
# STEP 3: SCENARIO B — FLAT EV BONUS DURING PEAK HOURS
# =============================================================================
# Policy: EVs get a flat cash bonus per trip during peak hours.
# This compensates for the surge cap in Scenario A.
# We test three bonus amounts: $20, $40, $60 per trip.
#
# Note: The spec uses ₹ (rupees) — we simulate in USD for consistency with
# the dataset. The logic is identical regardless of currency symbol.
# Change the bonus_values vector if you want to use rupee amounts.
# =============================================================================

cat("── STEP 3: Scenario B — EV peak-hour bonus ──\n")

# Exact spec: trips$earnings_B <- earnings + ifelse(is_ev & is_peak, 40, 0)
# We test three bonus levels and store all three

bonus_values <- c(20, 40, 60)   # USD per trip; change to ₹ values if needed

trips <- trips %>%
  mutate(
    # Start from Scenario A (cap already applied) — bonus compensates for the cap
    net_earn_B20 = round(net_earn_A + if_else(is_ev & is_peak,  20, 0), 2),
    net_earn_B40 = round(net_earn_A + if_else(is_ev & is_peak,  40, 0), 2),
    net_earn_B60 = round(net_earn_A + if_else(is_ev & is_peak,  60, 0), 2)
  )

# Build summary for each bonus level
scen_B_list <- map_dfr(bonus_values, function(bv) {
  col <- paste0("net_earn_B", bv)
  trips %>%
    group_by(vehicle_type) %>%
    summarise(
      scenario        = paste0("B: Surge cap + $", bv, " peak bonus"),
      bonus_amount    = bv,
      mean_net_earn   = round(mean(.data[[col]]),   3),
      median_net_earn = round(median(.data[[col]]), 3),
      total_revenue   = round(sum(fare_A), 2),   # fare unchanged — bonus is subsidy
      n_trips         = n(),
      fleet_share_pct = round(n() / nrow(trips) * 100, 1),
      .groups = "drop"
    )
})

# How many trips get the bonus?
peak_ev_trips <- sum(trips$is_ev & trips$is_peak)
cat("   EV peak trips eligible for bonus:", peak_ev_trips, "\n")
cat("   Cost of $40 bonus: $", peak_ev_trips * 40, " total\n")

# Plot: EV earnings across 3 bonus levels vs baseline
ev_bonus_compare <- tibble(
  label       = c("Baseline", "A: Cap only",
                  "B: Cap+$20", "B: Cap+$40", "B: Cap+$60"),
  mean_earn   = c(
    baseline_summary$mean_net_earn[baseline_summary$vehicle_type == "EV"],
    scen_A_summary$mean_net_earn[scen_A_summary$vehicle_type == "EV"],
    scen_B_list %>% filter(vehicle_type == "EV", bonus_amount == 20) %>%
      pull(mean_net_earn),
    scen_B_list %>% filter(vehicle_type == "EV", bonus_amount == 40) %>%
      pull(mean_net_earn),
    scen_B_list %>% filter(vehicle_type == "EV", bonus_amount == 60) %>%
      pull(mean_net_earn)
  ),
  type = c("Baseline","Cap only","Bonus","Bonus","Bonus")
)

baseline_ev_earn <- ev_bonus_compare$mean_earn[1]

p_B <- ggplot(ev_bonus_compare,
              aes(x = factor(label, levels = label), y = mean_earn,
                  fill = type)) +
  geom_col(width = 0.65, alpha = 0.88) +
  
  # Baseline reference line
  geom_hline(yintercept = baseline_ev_earn,
             linetype = "dashed", color = "grey30", linewidth = 0.8) +
  annotate("text", x = 0.5, y = baseline_ev_earn,
           label = "  Baseline", hjust = 0, vjust = -0.5,
           size = 2.8, color = "grey30") +
  
  # Value labels on bars
  geom_text(aes(label = paste0("$", round(mean_earn, 2))),
            vjust = -0.4, size = 3, color = "grey20") +
  
  scale_fill_manual(
    values = c("Baseline" = "#888780", "Cap only" = "#D85A30",
               "Bonus" = "#1D9E75"),
    name = NULL
  ) +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01),
                     expand = expansion(mult = c(0, 0.12))) +
  
  labs(
    title    = "Scenario B: EV peak-hour bonus — effect on mean EV earnings",
    subtitle = "Bonus added on top of Scenario A (1.5× surge cap) during peak hours only",
    x        = NULL, y = "Mean EV net earnings per trip (USD)",
    caption  = "Dashed line = baseline EV earnings | Goal: match or exceed baseline"
  ) + p5_theme +
  theme(axis.text.x = element_text(angle = 15, hjust = 1))

ggsave("plot_p5_scenario_B.png", p_B, width = 10, height = 5.5, dpi = 150)
cat("   ✅ plot_p5_scenario_B.png saved\n\n")


# =============================================================================
# STEP 4: SCENARIO C — EV RIDER DISCOUNT + PLATFORM SUBSIDY
# =============================================================================
# Policy: EVs charge riders 10% less during off-peak hours.
#         The platform subsidises the driver's lost fare (top-up).
#
# Two sub-scenarios:
#   C1: Rider gets 10% discount; driver absorbs the loss (no subsidy)
#   C2: Rider gets 10% discount; platform subsidises driver back to full fare
#
# Question: Does the discount drive EV demand up enough to offset the cut?
# We model demand uplift as +15% more EV trips at off-peak (price elasticity).
# =============================================================================

cat("── STEP 4: Scenario C — EV off-peak rider discount ──\n")

# Exact spec: trips$rider_fare_C <- ifelse(is_ev & !is_peak, fare*0.9, fare)
trips <- trips %>%
  mutate(
    # Rider pays 10% less on EV trips during off-peak
    rider_fare_C  = if_else(is_ev & !is_peak,
                            round(fare_A * 0.9, 2),   # 10% discount
                            fare_A),                   # full fare otherwise
    
    # C1: No subsidy — driver earns less when discount applied
    net_earn_C1   = round((rider_fare_C - operating_cost) *
                            (1 - commission_rate), 2),
    
    # C2: Platform subsidy — driver always gets paid as if full fare
    # Platform covers the 10% gap on off-peak EV trips
    subsidy_C2    = if_else(is_ev & !is_peak,
                            round(fare_A * 0.10 * (1 - commission_rate), 2),
                            0),
    net_earn_C2   = round(net_earn_C1 + subsidy_C2, 2)
  )

# Demand uplift model: assume -10% fare → +15% EV trip demand (price elasticity)
# Elasticity: price elasticity of demand ≈ -1.5 → 10% fare cut → 15% more trips
ev_offpeak_trips    <- sum(trips$is_ev & !trips$is_peak)
uplift_pct          <- 0.15   # 15% more EV off-peak trips
uplift_trips        <- round(ev_offpeak_trips * uplift_pct)

cat("   EV off-peak trips (current):", ev_offpeak_trips, "\n")
cat("   Estimated new EV trips (15% uplift):", uplift_trips, "\n")

scen_C_summary <- trips %>%
  group_by(vehicle_type) %>%
  summarise(
    scenario        = "C: Off-peak discount + subsidy",
    mean_net_earn   = round(mean(net_earn_C2),   3),
    median_net_earn = round(median(net_earn_C2), 3),
    total_revenue   = round(sum(rider_fare_C),   2),
    n_trips         = n(),
    fleet_share_pct = round(n() / nrow(trips) * 100, 1),
    .groups = "drop"
  )

# Plot: Earnings comparison C1 vs C2 vs Baseline (EV only)
ev_scen_C <- trips %>%
  filter(is_ev) %>%
  summarise(
    Baseline      = mean(base_net_earn),
    `C1: No subsidy`     = mean(net_earn_C1),
    `C2: With subsidy`   = mean(net_earn_C2)
  ) %>%
  pivot_longer(everything(), names_to = "scenario", values_to = "mean_earn") %>%
  mutate(scenario = factor(scenario, levels = c("Baseline",
                                                "C1: No subsidy",
                                                "C2: With subsidy")))

p_C <- ggplot(ev_scen_C, aes(x = scenario, y = mean_earn, fill = scenario)) +
  geom_col(width = 0.55, alpha = 0.88) +
  geom_text(aes(label = paste0("$", round(mean_earn, 2))),
            vjust = -0.4, size = 3.2, color = "grey20") +
  geom_hline(yintercept = ev_scen_C$mean_earn[ev_scen_C$scenario == "Baseline"],
             linetype = "dashed", color = "grey35", linewidth = 0.8) +
  scale_fill_manual(
    values = c("Baseline"           = "#888780",
               "C1: No subsidy"     = "#D85A30",
               "C2: With subsidy"   = "#1D9E75"),
    guide = "none"
  ) +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01),
                     expand = expansion(mult = c(0, 0.14))) +
  labs(
    title    = "Scenario C: EV off-peak 10% rider discount",
    subtitle = "C1 = driver absorbs discount | C2 = platform subsidises driver back to full fare",
    x        = NULL, y = "Mean EV net earnings per trip (USD)",
    caption  = paste0("Demand uplift assumption: 15% more EV off-peak trips (+",
                      uplift_trips, " estimated new trips)")
  ) + p5_theme

ggsave("plot_p5_scenario_C.png", p_C, width = 9, height = 5, dpi = 150)
cat("   ✅ plot_p5_scenario_C.png saved\n\n")


# =============================================================================
# STEP 5: COMPARE ALL SCENARIOS
# =============================================================================
# Build the master comparison table:
#   bind_rows(baseline, scen_A, scen_B, scen_C)
# Then plot:
#   1. Side-by-side earnings comparison
#   2. Pareto frontier: driver earnings vs EV adoption likelihood
#   3. Revenue impact waterfall
# =============================================================================

cat("── STEP 5: Full scenario comparison ──\n")

# ── 5a. Build master comparison table ─────────────────────────────────────────

# Add scenario column to baseline
baseline_tbl <- baseline_summary %>%
  mutate(scenario = "Baseline") %>%
  select(scenario, vehicle_type, mean_net_earn, median_net_earn,
         total_revenue, n_trips, fleet_share_pct)

# Scenario A
scen_A_tbl <- scen_A_summary %>%
  select(scenario, vehicle_type, mean_net_earn, median_net_earn,
         total_revenue, n_trips, fleet_share_pct)

# Scenario B: pick $40 bonus as primary (middle option)
scen_B_tbl <- scen_B_list %>%
  filter(bonus_amount == 40) %>%
  select(scenario, vehicle_type, mean_net_earn, median_net_earn,
         total_revenue, n_trips, fleet_share_pct)

# Scenario C: use C2 (with subsidy)
scen_C_tbl <- scen_C_summary %>%
  select(scenario, vehicle_type, mean_net_earn, median_net_earn,
         total_revenue, n_trips, fleet_share_pct)

# Exact spec: bind_rows(baseline, scen_A, scen_B, scen_C)
comparison_table <- bind_rows(baseline_tbl, scen_A_tbl,
                              scen_B_tbl, scen_C_tbl) %>%
  arrange(scenario, vehicle_type)

cat("\n   ── Master comparison table ──\n")
print(comparison_table, n = 30)

write_csv(comparison_table, "scenario_comparison.csv")
cat("\n   ✅ scenario_comparison.csv saved\n")

# ── 5b. EV-only summary for Pareto analysis ───────────────────────────────────
# For Pareto: we want scenarios where BOTH metrics are high:
#   x-axis: EV earnings (driver welfare)
#   y-axis: EV adoption likelihood proxy (how much EV earnings exceed Non-EV)

nonev_baseline_earn <- baseline_summary$mean_net_earn[
  baseline_summary$vehicle_type == "Non-EV"]

pareto_data <- comparison_table %>%
  group_by(scenario) %>%
  summarise(
    ev_mean_earn    = mean_net_earn[vehicle_type == "EV"],
    nonev_mean_earn = mean_net_earn[vehicle_type == "Non-EV"],
    total_rev       = sum(total_revenue),
    .groups = "drop"
  ) %>%
  mutate(
    # Adoption incentive: how much MORE do EVs earn vs Non-EV?
    # Positive = EVs earn more → more drivers would switch
    ev_advantage    = round(ev_mean_earn - nonev_mean_earn, 3),
    
    # Revenue impact: total revenue vs baseline
    rev_vs_baseline = round(total_rev -
                              sum(baseline_tbl$total_revenue), 2),
    
    # Driver welfare score: EV earnings as % of baseline EV earnings
    welfare_score   = round(ev_mean_earn /
                              baseline_summary$mean_net_earn[baseline_summary$vehicle_type == "EV"] * 100, 1),
    
    # Adoption score: normalised EV advantage (0–100)
    adoption_score  = round(
      scales::rescale(ev_advantage, to = c(0, 100)), 1
    )
  )

cat("\n   ── Pareto analysis ──\n")
print(pareto_data)

# ── 5c. Plot: Side-by-side earnings across all scenarios ──────────────────────
earn_plot_data <- comparison_table %>%
  mutate(scenario = factor(scenario,
                           levels = c("Baseline", "A: Surge cap 1.5×",
                                      "B: Surge cap + $40 peak bonus",
                                      "C: Off-peak discount + subsidy")))

p_compare <- ggplot(earn_plot_data,
                    aes(x = scenario, y = mean_net_earn,
                        fill = vehicle_type, group = vehicle_type)) +
  
  geom_col(position = position_dodge(0.75), width = 0.65, alpha = 0.88) +
  
  # Baseline EV reference line
  geom_hline(yintercept = baseline_summary$mean_net_earn[
    baseline_summary$vehicle_type == "EV"],
    linetype = "dashed", color = "#1D9E75", linewidth = 0.7) +
  annotate("text", x = 0.4,
           y = baseline_summary$mean_net_earn[baseline_summary$vehicle_type == "EV"],
           label = "  EV baseline", hjust = 0, vjust = -0.5,
           size = 2.6, color = "#1D9E75") +
  
  # Value labels
  geom_text(aes(label = paste0("$", round(mean_net_earn, 1))),
            position = position_dodge(0.75),
            vjust = -0.4, size = 2.6, color = "grey20") +
  
  scale_fill_manual(values = ev_colors, name = "Vehicle type") +
  scale_y_continuous(labels = label_dollar(accuracy = 0.01),
                     expand = expansion(mult = c(0, 0.14))) +
  
  labs(
    title    = "Scenario comparison — mean net earnings per trip",
    subtitle = "All scenarios vs baseline | EV and Non-EV side-by-side",
    x        = NULL, y = "Mean net earnings (USD)",
    caption  = "Scenario B uses $40 peak bonus | Scenario C uses platform subsidy (C2)"
  ) + p5_theme +
  theme(axis.text.x = element_text(angle = 15, hjust = 1, size = 9))

ggsave("plot_p5_comparison_table.png", p_compare, width = 12, height = 6, dpi = 150)
cat("   ✅ plot_p5_comparison_table.png saved\n")

# ── 5d. Plot: Pareto frontier — driver welfare vs EV adoption ─────────────────
# A scenario is Pareto-optimal if no other scenario does better on BOTH axes.

p_pareto <- ggplot(pareto_data,
                   aes(x = welfare_score, y = ev_advantage)) +
  
  # Quadrant shading: top-right = ideal
  annotate("rect", xmin = 100, xmax = Inf, ymin = 0, ymax = Inf,
           fill = "#EAF3DE", alpha = 0.5) +
  annotate("text", x = 101, y = max(pareto_data$ev_advantage) * 0.95,
           label = "Ideal zone\n(high welfare +\nhigh adoption)",
           hjust = 0, size = 2.8, color = "#3B6D11", fontface = "italic") +
  
  # Reference lines at baseline values
  geom_vline(xintercept = 100, linetype = "dashed",
             color = "grey40", linewidth = 0.7) +
  geom_hline(yintercept = pareto_data$ev_advantage[pareto_data$scenario == "Baseline"],
             linetype = "dashed", color = "grey40", linewidth = 0.7) +
  
  # Points sized by total revenue
  geom_point(aes(size = abs(rev_vs_baseline) / 1000 + 3,
                 color = scenario),
             alpha = 0.85) +
  
  # Labels with ggrepel (no overlap)
  geom_text_repel(aes(label = scenario, color = scenario),
                  size = 3, fontface = "bold",
                  max.overlaps = 10, seed = 42) +
  
  scale_color_manual(
    values = c("Baseline"                        = "#888780",
               "A: Surge cap 1.5×"               = "#D85A30",
               "B: Surge cap + $40 peak bonus"   = "#1D9E75",
               "C: Off-peak discount + subsidy"  = "#185FA5"),
    guide = "none"
  ) +
  scale_size_continuous(range = c(4, 10), guide = "none") +
  
  labs(
    title    = "Pareto analysis — driver welfare vs EV adoption incentive",
    subtitle = "Top-right = best: EV drivers earn more (welfare) AND have more reason to switch (adoption)",
    x        = "Driver welfare score (EV earnings as % of baseline, 100 = same as baseline)",
    y        = "EV earnings advantage over Non-EV (USD per trip)",
    caption  = "Pareto-optimal: scenario where no other option is better on both axes simultaneously"
  ) + p5_theme +
  theme(legend.position = "none")

ggsave("plot_p5_pareto.png", p_pareto, width = 10, height = 6.5, dpi = 150)
cat("   ✅ plot_p5_pareto.png saved\n")

# ── 5e. Plot: Earnings bump chart — EV journey across scenarios ───────────────
# Tracks how EV mean earnings move from Baseline → A → B → C

ev_journey <- comparison_table %>%
  filter(vehicle_type == "EV") %>%
  mutate(scenario = factor(scenario,
                           levels = c("Baseline", "A: Surge cap 1.5×",
                                      "B: Surge cap + $40 peak bonus",
                                      "C: Off-peak discount + subsidy")),
         label_pos = mean_net_earn)

p_bump <- ggplot(ev_journey,
                 aes(x = scenario, y = mean_net_earn, group = 1)) +
  geom_line(color = "#1D9E75", linewidth = 1.4) +
  geom_point(size = 5, color = "#1D9E75", fill = "white",
             shape = 21, stroke = 2) +
  geom_text(aes(label = paste0("$", round(mean_net_earn, 2))),
            vjust = -1.1, size = 3.2, color = "#085041", fontface = "bold") +
  
  # Baseline reference
  geom_hline(yintercept = ev_journey$mean_net_earn[
    ev_journey$scenario == "Baseline"],
    linetype = "dotted", color = "grey50", linewidth = 0.8) +
  
  scale_y_continuous(labels = label_dollar(accuracy = 0.01),
                     expand = expansion(mult = c(0.1, 0.15))) +
  
  labs(
    title    = "EV driver earnings trajectory across scenarios",
    subtitle = "How does mean EV net earnings per trip change from Baseline → A → B → C?",
    x        = NULL, y = "Mean EV net earnings (USD)",
    caption  = "Dotted line = baseline | Goal: end higher than baseline or at parity"
  ) + p5_theme +
  theme(axis.text.x = element_text(angle = 12, hjust = 1))

ggsave("plot_p5_earnings_bump.png", p_bump, width = 10, height = 5.5, dpi = 150)
cat("   ✅ plot_p5_earnings_bump.png saved\n")


# =============================================================================
# FINAL SUMMARY + RECOMMENDATION
# =============================================================================

cat("\n══════════════════════════════════════════════════\n")
cat("PHASE 5 COMPLETE — All scenarios simulated!\n")
cat("══════════════════════════════════════════════════\n\n")

cat("📊 Plots saved:\n")
cat("   plot_p5_baseline.png         ← Baseline earnings by zone\n")
cat("   plot_p5_scenario_A.png       ← EV earnings distribution: cap vs no cap\n")
cat("   plot_p5_scenario_B.png       ← Bonus level comparison ($20/$40/$60)\n")
cat("   plot_p5_scenario_C.png       ← Off-peak discount C1 vs C2\n")
cat("   plot_p5_comparison_table.png ← All 4 scenarios side-by-side\n")
cat("   plot_p5_pareto.png           ← Pareto frontier scatter\n")
cat("   plot_p5_earnings_bump.png    ← EV earnings trajectory\n")

cat("\n📁 Data saved:\n")
cat("   scenario_comparison.csv      ← Full comparison table\n")

cat("\n📌 Pareto-optimal scenario:\n")
best_scenario <- pareto_data %>%
  filter(welfare_score >= 95) %>%   # EV earnings within 5% of baseline
  slice_max(ev_advantage, n = 1)

if (nrow(best_scenario) > 0) {
  cat("   ✅", best_scenario$scenario, "\n")
  cat("      Welfare score :", best_scenario$welfare_score, "% of baseline\n")
  cat("      EV advantage  : $", best_scenario$ev_advantage, " over Non-EV\n")
  cat("      Revenue impact: $", best_scenario$rev_vs_baseline, "vs baseline\n")
} else {
  cat("   ⚠️  No scenario fully dominates — check plot_p5_pareto.png\n")
  cat("   Recommendation: Scenario B ($40 bonus) or C2 (subsidy)\n")
  cat("   → Both restore EV earnings while maintaining adoption incentive\n")
}

cat("\n📌 Key numbers for your report:\n")
cat("   Baseline EV mean earn    : $",
    baseline_summary$mean_net_earn[baseline_summary$vehicle_type == "EV"], "\n")
cat("   Baseline Non-EV mean earn: $",
    baseline_summary$mean_net_earn[baseline_summary$vehicle_type == "Non-EV"], "\n")
cat("   EV fleet share           :",
    baseline_summary$fleet_share_pct[baseline_summary$vehicle_type == "EV"], "%\n")

cat("\nAll phases complete! Check scenario_comparison.csv for report tables.\n")