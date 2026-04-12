#!/usr/bin/env Rscript
# =============================================================================
# STANDALONE INTERACTIVE HTML DEMO
# Purpose: Backup option if Shiny doesn't launch
# Usage: Just run this script - generates demo_dashboard.html
# =============================================================================

library(tidyverse)
library(plotly)
library(htmltools)

cat("Generating standalone HTML dashboard...\n")

# Load data
trips   <- read_csv("data/trips_data_with_surge_pred.csv", show_col_types = FALSE)
demand  <- read_csv("data/demand_data_with_predictions.csv", show_col_types = FALSE)
drivers <- read_csv("data/driver_data.csv", show_col_types = FALSE)

# ── Create all plots ──────────────────────────────────────────────────────

# Plot 1: Earnings Comparison
p1 <- plot_ly(
  x = c("Baseline", "Scenario B"),
  y = c(24.11, 30.02),
  type = "bar",
  marker = list(color = c("#D85A30", "#1D9E75")),
  text = c("$24.11", "$30.02"),
  textposition = "outside"
) %>%
  layout(
    title = "EV Driver Earnings: Baseline vs Scenario B",
    yaxis = list(title = "Earnings per Trip ($)"),
    showlegend = FALSE,
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# Plot 2: Adoption S-Curve
bonus_levels <- seq(0, 80, 5)
adoption_rate <- c(40, 42, 46, 48, 52, 55, 58, 62, 65, 68, 70, 72, 74, 76, 78, 80, 82)

p2 <- plot_ly(
  x = bonus_levels,
  y = adoption_rate,
  type = "scatter",
  mode = "lines+markers",
  name = "Adoption Rate",
  line = list(color = "#1f77b4", width = 3),
  marker = list(size = 8)
) %>%
  add_segments(
    x = 40, xend = 40, y = 0, yend = 65,
    line = list(dash = "dash", color = "red"),
    name = "Optimal ($40)",
    showlegend = TRUE
  ) %>%
  layout(
    title = "EV Adoption vs Bonus Level (S-Curve)",
    xaxis = list(title = "Bonus Amount ($)"),
    yaxis = list(title = "Adoption Rate (%)"),
    showlegend = TRUE,
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# Plot 3: Demand by Zone and Hour
heatmap_data <- demand %>%
  group_by(zone, hour) %>%
  summarise(avg_demand = mean(trip_count, na.rm = TRUE), .groups = "drop") %>%
  mutate(hour = as.numeric(hour))

p3 <- plot_ly(
  heatmap_data,
  x = ~hour,
  y = ~zone,
  z = ~avg_demand,
  type = "heatmap",
  colorscale = "Viridis"
) %>%
  layout(
    title = "Demand Heatmap: Zone × Hour",
    xaxis = list(title = "Hour of Day"),
    yaxis = list(title = "Zone"),
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# Plot 4: Earnings vs Surge
p4 <- plot_ly(
  trips,
  x = ~surge_multiplier,
  y = ~driver_net_usd,
  color = ~vehicle_type,
  type = "scatter",
  mode = "markers",
  marker = list(size = 5, opacity = 0.6),
  colors = c("EV" = "#1D9E75", "Non-EV" = "#D85A30"),
  text = ~paste("Zone:", zone, "<br>Distance:", round(distance_km, 1), "km<br>Surge:", surge_multiplier, "x"),
  hoverinfo = "text"
) %>%
  layout(
    title = "Driver Net Earnings vs Surge Multiplier",
    xaxis = list(title = "Surge Multiplier"),
    yaxis = list(title = "Driver Net Earnings ($)"),
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# Plot 5: Scenario Comparison Bar Chart
scenario_df <- data.frame(
  Scenario = c("Baseline", "A: Cap\nOnly", "B: Cap +\nBonus\n(Recommended)", "C: Off-Peak\nSubsidy"),
  Earnings = c(24.11, 21.58, 30.02, 18.40),
  Color = c("#D85A30", "#ff4d4d", "#1D9E75", "#ffb84d")
)

p5 <- plot_ly(
  scenario_df,
  x = ~Scenario,
  y = ~Earnings,
  type = "bar",
  marker = list(color = ~Color),
  text = ~paste("$", round(Earnings, 2)),
  textposition = "outside"
) %>%
  layout(
    title = "Scenario Comparison: EV Driver Earnings",
    yaxis = list(title = "Earnings per Trip ($)"),
    showlegend = FALSE,
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# Plot 6: Model Performance Metrics
model_metrics <- data.frame(
  Model = c("Random Forest\n(Demand)", "XGBoost\n(Surge)", "Logistic Reg.\n(Adoption)"),
  R2_or_AUC = c(0.9875, 0.8126, 0.7787),
  Metric_Name = c("R²", "R²", "AUC")
)

p6 <- plot_ly(
  model_metrics,
  x = ~Model,
  y = ~R2_or_AUC,
  type = "bar",
  marker = list(color = c("#1f77b4", "#ff7f0e", "#2ca02c")),
  text = ~paste(Metric_Name, "=", round(R2_or_AUC, 4)),
  textposition = "outside"
) %>%
  layout(
    title = "Model Performance Metrics",
    yaxis = list(title = "Performance Score (0-1)", range = c(0, 1.1)),
    showlegend = FALSE,
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# Plot 7: Distribution of Surge Across All Trips
p7 <- plot_ly(
  trips,
  x = ~surge_multiplier,
  type = "histogram",
  nbinsx = 25,
  marker = list(color = "#1f77b4")
) %>%
  layout(
    title = "Distribution of Surge Multipliers",
    xaxis = list(title = "Surge Multiplier"),
    yaxis = list(title = "Frequency"),
    showlegend = FALSE,
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# Plot 8: Distance vs Final Fare by Vehicle Type
p8 <- plot_ly(
  trips,
  x = ~distance_km,
  y = ~final_fare_usd,
  color = ~vehicle_type,
  type = "scatter",
  mode = "markers",
  marker = list(size = 5, opacity = 0.6),
  colors = c("EV" = "#1D9E75", "Non-EV" = "#D85A30"),
  text = ~paste("Hour:", hour, "<br>Zone:", zone),
  hoverinfo = "text"
) %>%
  layout(
    title = "Trip Fare vs Distance by Vehicle Type",
    xaxis = list(title = "Distance (km)"),
    yaxis = list(title = "Final Fare ($)"),
    margin = list(t = 50, b = 50, l = 50, r = 50)
  )

# ── Create HTML page ──────────────────────────────────────────────────────

html_content <- tags$html(
  tags$head(
    tags$title("EV Dynamic Pricing - Interactive Demo"),
    tags$style(HTML("
      body {
        font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        margin: 0;
        padding: 20px;
      }
      .container {
        max-width: 1400px;
        margin: 0 auto;
        background: white;
        border-radius: 10px;
        box-shadow: 0 10px 40px rgba(0,0,0,0.3);
        padding: 40px;
      }
      h1 {
        color: #2c3e50;
        text-align: center;
        margin: 0 0 10px 0;
        font-size: 2.5em;
      }
      .subtitle {
        text-align: center;
        color: #7f8c8d;
        margin: 0 0 40px 0;
        font-size: 1.1em;
      }
      .key-metrics {
        display: grid;
        grid-template-columns: repeat(4, 1fr);
        gap: 20px;
        margin: 30px 0;
      }
      .metric-box {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        color: white;
        padding: 20px;
        border-radius: 8px;
        text-align: center;
        box-shadow: 0 4px 15px rgba(0,0,0,0.2);
      }
      .metric-box h3 {
        margin: 0;
        font-size: 2em;
      }
      .metric-box p {
        margin: 5px 0 0 0;
        font-size: 0.9em;
      }
      .plots-grid {
        display: grid;
        grid-template-columns: repeat(2, 1fr);
        gap: 30px;
        margin: 30px 0;
      }
      .plot-container {
        background: #f8f9fa;
        padding: 20px;
        border-radius: 8px;
        box-shadow: 0 2px 8px rgba(0,0,0,0.1);
      }
      .plot-title {
        font-size: 1.2em;
        font-weight: bold;
        margin: 0 0 10px 0;
        color: #2c3e50;
      }
      .recommendation-box {
        background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
        color: white;
        padding: 30px;
        border-radius: 8px;
        margin: 30px 0;
        text-align: center;
      }
      .recommendation-box h2 {
        margin: 0 0 10px 0;
      }
      .recommendation-box h1 {
        color: white;
        margin: 0;
      }
      .footer {
        text-align: center;
        color: #7f8c8d;
        margin-top: 40px;
        font-size: 0.9em;
      }
      @media (max-width: 1200px) {
        .plots-grid {
          grid-template-columns: 1fr;
        }
        .key-metrics {
          grid-template-columns: repeat(2, 1fr);
        }
      }
    "))
  ),
  tags$body(
    div(class = "container",
      h1("🚗 EV Dynamic Pricing Analysis"),
      p(class = "subtitle", "Interactive Dashboard Demo"),
      
      # Key Metrics
      div(class = "key-metrics",
        div(class = "metric-box",
          h3("$24.11"),
          p("EV Baseline Earnings/trip")
        ),
        div(class = "metric-box",
          h3("$30.02"),
          p("Scenario B (Recommended)")
        ),
        div(class = "metric-box",
          h3("65-70%"),
          p("Expected EV Adoption")
        ),
        div(class = "metric-box",
          h3("$8/trip"),
          p("Platform Cost (Peak)")
        )
      ),
      
      # Recommendation
      div(class = "recommendation-box",
        h2("PRIMARY RECOMMENDATION"),
        h1("Scenario B: $40 Peak-Hour Bonus"),
        p("Increases EV earnings to $30.02/trip (+24.5%) and adoption to 65-70%")
      ),
      
      # Plots
      div(class = "plots-grid",
        div(class = "plot-container",
          p(class = "plot-title", "Earnings Comparison"),
          plotlyOutput(renderPlotly(p1))
        ),
        div(class = "plot-container",
          p(class = "plot-title", "Adoption S-Curve (Tipping Point = $40)"),
          plotlyOutput(renderPlotly(p2))
        ),
        div(class = "plot-container",
          p(class = "plot-title", "Demand Heatmap by Zone & Hour"),
          plotly::as_widget(p3)
        ),
        div(class = "plot-container",
          p(class = "plot-title", "Earnings vs Surge Multiplier"),
          plotly::as_widget(p4)
        ),
        div(class = "plot-container",
          p(class = "plot-title", "All Scenarios Compared"),
          plotly::as_widget(p5)
        ),
        div(class = "plot-container",
          p(class = "plot-title", "Model Performance Metrics"),
          plotly::as_widget(p6)
        ),
        div(class = "plot-container",
          p(class = "plot-title", "Surge Multiplier Distribution"),
          plotly::as_widget(p7)
        ),
        div(class = "plot-container",
          p(class = "plot-title", "Trip Fare vs Distance"),
          plotly::as_widget(p8)
        )
      ),
      
      # Summary
      div(
        h2("Key Findings"),
        tags$ul(
          tags$li("EV drivers already earn 9.4% more per trip in baseline"),
          tags$li("Scenario B ($40 peak bonus) boosts earnings to $30.02 (+24.5%)"),
          tags$li("Adoption increases from 40% to 65-70% with Scenario B"),
          tags$li("Random Forest demand forecasting: R² = 0.9875 (excellent)"),
          tags$li("XGBoost surge prediction: R² = 0.8126 (very good)"),
          tags$li("Logistic adoption model: AUC = 0.7787 (good)"),
          tags$li("$40 is the S-curve tipping point - minimal diminishing returns"),
          tags$li("Platform cost of ~$8/peak trip is economically sustainable")
        )
      ),
      
      # Footer
      p(class = "footer",
        "This dashboard demonstrates live interactive visualizations of the EV Pricing Analysis.<br>",
        "All data, models, and code are reproducible and available in the project directory.")
    )
  )
)

# Save to HTML file
saveRDS(html_content, "demo_dashboard_content.rds")

# Alternative: Save as raw HTML using htmltools
write_file(
  as.character(html_content),
  "demo_dashboard.html"
)

cat("✓ HTML Dashboard generated: demo_dashboard.html\n")
cat("✓ Open in any web browser to view interactive demo\n")

# Launch browser automatically
browseURL("demo_dashboard.html")
