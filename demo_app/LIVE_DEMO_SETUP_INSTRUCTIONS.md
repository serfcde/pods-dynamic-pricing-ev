# 🎬 LIVE DEMO SETUP GUIDE
## How to Run Interactive Dashboard for Your Professor

---

## 🚀 QUICK START (5 minutes)

### Option 1: Shiny Interactive Dashboard (RECOMMENDED)

**Step 1: Install Required Packages** (Run ONCE in RStudio console)
```r
# Copy-paste this into RStudio console and press Enter
required_packages <- c("shiny", "tidyverse", "plotly", "DT", "shinydashboard", "xgboost")
install.packages(required_packages)
```

**Step 2: Launch the App**
```r
# In RStudio console, type:
shiny::runApp("shiny_demo_app.R")

# OR open shiny_demo_app.R and click "Run App" button (top-right of editor)
```

**Step 3: View in Browser**
- App opens automatically in your browser (usually http://localhost:3838)
- Maximize browser window for projector display
- Profit! 🎉

**Duration**: ~30 seconds to launch after packages installed

---

## 🎯 WHAT THE DEMO SHOWS YOUR PROFESSOR

### Dashboard Tab (Opening Screen)
- ✅ Baseline EV earnings ($24.11/trip)
- ✅ Scenario B recommendation (+24.5% to $30.02)
- ✅ Model performance metrics (R², AUC)
- ✅ Two key charts: Earnings comparison + S-curve adoption

### Model Predictions Tab
**Interactive Demo**:
1. Left sidebar: Select zone (Downtown, Airport, Midtown, Suburbs)
2. Select hour (0-23)
3. Adjust bonus amount ($0-100)
4. Click **"Make Live Prediction"** button
5. Live output shows:
   - **Demand forecast** (from Random Forest)
   - **Surge multiplier** (from XGBoost)
   - **Adoption probability** (from Logistic Regression)
6. Interactive heatmap + distribution plots below

### Scenario Analysis Tab
- **Dynamic comparison**: Change the bonus slider → see adoption/earnings update in real-time
- Table comparing all 4 scenarios (Baseline, A, B, C)
- Bar charts showing earnings and adoption rates

### Data Explorer Tab
- Interactive scatter plots: hover over points to see values
- Trip patterns by zone, hour, vehicle type
- Earnings vs surge scatter plot
- Raw data table (first 100 trips)

### Model Metrics Tab
- Side-by-side comparison of all 3 models
- Performance metrics (R², AUC, RMSE, etc.)
- Feature importance visualization
- Model diagnostic summary

---

## ⚙️ INSTALLATION DETAILS (First Time Only)

### If You Don't Have Required Packages:

**Option A: Install All at Once** (Easiest)
```r
pkgs <- c("shiny", "tidyverse", "plotly", "DT", "shinydashboard", "xgboost")
install.packages(pkgs)
```

**Option B: Troubleshooting Specific Packages**

If `shiny` fails:
```r
install.packages("shiny")
# Wait ~2 minutes, ignore warnings about dependencies
```

If `plotly` fails:
```r
install.packages("plotly")
# Wait ~1 minute
```

If `xgboost` fails (most likely):
```r
# Try CRAN first:
install.packages("xgboost")

# If that fails, try conda:
# conda install -c conda-forge xgboost
# OR manual install from source
```

**Check Installation**:
```r
# Paste this in console. If TRUE appears, you're good:
all(c("shiny","tidyverse","plotly","DT","shinydashboard","xgboost") %in% rownames(installed.packages()))
```

---

## 📋 DAY-OF CHECKLIST

**Morning Before Presentation**:
- [ ] Laptop fully charged
- [ ] WiFi/Network stable (Shiny doesn't need internet, but good to have)
- [ ] Test app launch: Take 30 seconds, click "Run App"
- [ ] Verify all plots load (may take 10-15 seconds first time)
- [ ] Close app and relaunch to confirm it works again

**Presentation Setup** (10 min before):
1. Connect laptop to projector
2. Open RStudio
3. Open file: `shiny_demo_app.R`
4. Click "Run App" button (top right of script editor)
5. Wait ~15 seconds for browser to open
6. Maximize browser window
7. You're ready!

**During Presentation**:
- Show Dashboard tab first (big picture overview)
- Click to Model Predictions tab → make a live prediction with professor's chosen zone/hour
- Adjust bonus slider to show adoption changes in real-time
- Show Scenario tab to compare policies
- Use Data Explorer if they ask "can you show me the raw data?"
- Keep Model Metrics tab in back pocket if technical questions emerge

---

## 🎪 LIVE DEMO SCRIPT (Run Through With Professor)

### Minute 1-2: Dashboard Overview
```
"Here's the dashboard view - you can see my key findings at a glance:
- EV drivers currently earn $24.11 per trip (40% adoption)
- My recommendation (Scenario B) increases earnings to $30.02 (+24.5%)
- This is expected to boost adoption to 65-70%
- The models achieve R² = 0.9875 and AUC = 0.7787"
```

### Minute 2-4: Live Predictions
```
"Now let me show you the models in action. I have three predictive models:

First, I'll select a zone - let's say Downtown at 6 PM (peak hour).
[Click dropdown, select Downtown, select hour 18]

Now I click 'Make Live Prediction' and get:
- Random Forest predicted demand: ~85 trips in Downtown at 6 PM
- XGBoost surge multiplier: 2.1× (high surge during rush hour)
- Logistic Regression adoption: 68% likelihood this driver adopts EV

You can see how demand drives surge, and surge influences adoption decision."
```

### Minute 4-6: Scenario Testing
```
"Here's where it gets interesting - scenario analysis.

Currently the bonus is set to $40 (my recommendation).
Watch what happens if I increase it to $60...
[Adjust slider]

See how adoption jumps from 65% to 82%? But the cost also goes up.
If I decrease to $30...
Adoption drops to 52% - we lose the benefit.

$40 is the sweet spot - it's where the S-curve has the steepest slope."
```

### Minute 6-7: Wrap Up
```
"The data is interactive and reproducible. Every model is saved.
The heatmaps show demand byzone and hour - you can see why peak-hour 
bonuses make sense. The data explorer lets you dig into individual trips.

This isn't just analysis - it's a working system ready for implementation."
```

---

## 🛠️ TROUBLESHOOTING

### "App won't start - Error message about packages"
**Solution**: Install missing package
```r
# Replace PACKAGE_NAME with the name in error
install.packages("PACKAGE_NAME")
```

### "Plots not loading / blank"
**Solution**: 
1. Close app (press Escape or Ctrl+C in console)
2. Reload data:
```r
# In RStudio console:
trips <- read_csv("trips_data_with_surge_pred.csv", show_col_types = FALSE)
demand <- read_csv("demand_data_with_predictions.csv", show_col_types = FALSE)
```
3. Restart app: `shiny::runApp("shiny_demo_app.R")`

### "Make Live Prediction button doesn't work"
**Solution**: Make sure you're in the right working directory
```r
# Check current directory:
getwd()

# Should output: "e:/VIT Vellore/3rd Year/6th Sem/D - Programming for DS/Project/Final"
# If not, set it:
setwd("e:/VIT Vellore/3rd Year/6th Sem/D - Programming for DS/Project/Final")
```

### "Models won't load (xgboost error)"
**Solution**: xgboost is tricky. Try:
```r
# Option 1: Force reinstall
install.packages("xgboost", force = TRUE)

# Option 2: Or use conda (if you have it):
# conda install -c conda-forge xgboost

# Option 3: If still failing, comment out XGBoost parts
# and use simpler demo (see alternative below)
```

### "Everything's too slow"
**Solution**: This is normal first load with Plotly
- First time: ~15-20 seconds (Plotly rendering)
- After that: 2-3 seconds per tab
- Hover over plots may be slightly slow initially

---

## 📱 ALTERNATIVE: Static HTML Demo (No RStudio Needed)

If Shiny/R doesn't work, use this simpler HTML dashboard:

**To create it**:
1. Run this R command:
```r
source("phase7_policy_recommendation.Rmd")  # Renders HTML
```

2. Or open the RMarkdown file (`phase7_policy_recommendation.Rmd`) and click **"Knit to HTML"**

3. This generates `phase7_policy_recommendation.html` - open in browser for static but complete demo

**Advantage**: No troubleshooting needed, works anywhere  
**Disadvantage**: Not interactive (can't change bonus dynamically)

---

## 🎬 LIVE DEMO TIMELINE

```
T-15 min: Connect to projector, test Shiny launch
T-5 min:  Open RStudio, load shiny_demo_app.R
T-0 min:  Click "Run App", browser opens
T+0 min:  Show Dashboard tab overview (30 seconds)
T+0:30:   Click to Model Predictions tab
T+1 min:  Make live prediction with professor's zone/hour choice
T+2 min:  Show Scenario Analysis - adjust bonus slider
T+3 min:  Show Data Explorer - scatter plots
T+4 min:  Wrap up, field questions
```

**Total Demo**: ~4 minutes  
**With Q&A**: ~10 minutes

---

## 🎯 KEY POINTS TO EMPHASIZE DURING DEMO

1. **Interactive**: "This isn't just static slides - you can see the models actually predicting in real-time"

2. **Data-Driven**: "Every prediction is based on the three models you see here - Random Forest, XGBoost, and Logistic Regression"

3. **Multiple Perspectives**: 
   - Demand view (how busy is this zone?)
   - Surge view (what's the multiplier?)
   - Adoption view (will drivers switch to EV?)

4. **Scenario Planning**: "You can adjust parameters and instantly see how adoption and cost change"

5. **Reproducible**: "All code, data, and models are saved. You could run this yourself"

---

## 💡 PROFESSOR WILL LOVE THIS BECAUSE:

✅ **Shows you can deploy models** (not just train them)  
✅ **Interactive demo** (better than static slides)  
✅ **Real-time predictions** (impressive live performance)  
✅ **Multiple visualizations** (comprehensive coverage)  
✅ **Professional presentation** (business-ready dashboard)  
✅ **Data transparency** (explore raw data if questioned)

---

## 📝 SCRIPT FOR DEMO (Full Version)

**Opening (30 sec)**:
```
"I've built an interactive dashboard that brings my analysis to life.
It lets you explore the three predictive models in real-time and see
how different policy scenarios affect adoption and earnings."
```

**Dashboard Tab (1 min)**:
```
"At a glance: EV drivers earn $24.11/trip with 40% adoption currently.
My analysis recommends Scenario B - a $40 peak-hour bonus - which would 
increase earnings to $30.02 (+24.5%) and adoption to 65-70%.

The models are strong: Random Forest explains 98.75% of demand variance,
and the adoption model achieves 77.87% AUC.

Let me show you these models in action."
```

**Predictions Tab (2 min)**:
```
"I have three predictive models working together:

First, the Random Forest forecasts hourly demand by zone and time.
Then XGBoost predicts the surge multiplier based on that predicted demand.
Finally, Logistic Regression estimates driver EV adoption likelihood.

Let me demo - Professor, pick a zone and hour. [Wait for response]
Downtown at 6 PM? Great choice - that's peak rush hour.

[Click dropdown, select values, click "Make Live Prediction"]

Look at this: Random Forest predicts 85 trips in Downtown at 6 PM.
XGBoost shows a 2.1× surge multiplier - high surge during rush.
That high surge and demand signal makes drivers 68% likely to adopt EV.

You can see the logic: when demand and surge are high, EV economics work best."
```

**Scenario Tab (1.5 min)**:
```
"Now the key business question: what bonus optimizes adoption?

Currently I'm showing $40 - my recommendation. 
But watch what happens if I change it...

[Adjust slider to $60]
Adoption jumps to 82%! Looks good, right?
But cost also increases 50%. That's diminishing returns.

[Adjust to $30]
Now adoption drops to 52%. We lose the momentum.

[Set back to $40]
$40 is the sweet spot - steepest slope on the S-curve.
That's why this is my recommendation."
```

**Data Explorer (optional, if asked)**:
```
"Here's the underlying data - 5,000 individual trips with all features.
You can see the scatter plot: earnings vs surge, distance vs fare.
Everything is transparent and verifiable."
```

**Closing (30 sec)**:
```
"This dashboard demonstrates that the analysis isn't just theory.
The models work. The predictions make sense. And the policy recommendation
(Scenario B) is optimized based on data, not intuition.

This is a complete, deployable system."
```

---

## ✅ YOU'RE READY!

Just follow the Quick Start above and you'll have a **professional, interactive demo** running in <5 minutes. 

Your professor will see:
- ✅ Live predictions from trained models
- ✅ Interactive exploration of data
- ✅ Real-time scenario comparison
- ✅ Complete model metrics
- ✅ Raw data transparency

**This is impressive. Go get 'em!** 🚀

---

**Questions?** Check troubleshooting section above or verify your working directory is correct.
