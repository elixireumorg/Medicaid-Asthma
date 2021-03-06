##########################################################
# Generate data for U01 prediction model
# This code identifies children with an asthma-related claim in 2014.
# It then looks at risk factors for asmtha-related hospital or ED visits in 2015

# APDE, PHSKC
# SQL code by Lin Song, edited by Alastair Matheson to work in R and include medication
# 2016-05-26
##########################################################

options(max.print = 400, scipen = 0)


library(RODBC) # used to connect to SQL server
library(dplyr) # used to manipulate data
library(reshape2) # used to reshape data
library(car) # used to recode variables
library(haven) # used to read in Stata files
library(lmtest) # used to conduct likelihood ratio tests
library(rms) # used for other model diagnostics


# DATA SETUP --------------------------------------------------------------

### Connect to the server
db.claims <- odbcConnect("PHClaims")


##### Bring in all the relevant eligibility data #####

# Bring in 2014 data for children aged 3-17 (born between 1997-2011) in 2014
ptm01 <- proc.time() # Times how long this query takes (~21 secs)
elig <-
  sqlQuery(
    db.claims,
    "SELECT CAL_YEAR AS 'Year', MEDICAID_RECIPIENT_ID AS 'ID2014', SOCIAL_SECURITY_NMBR AS 'SSN',
    GENDER AS 'Gender', RACE1  AS 'Race1', RACE2 AS 'Race2', HISPANIC_ORIGIN_NAME AS 'Hispanic',
    BIRTH_DATE AS 'DOB', CTZNSHP_STATUS_NAME AS 'Citizenship', INS_STATUS_NAME AS 'Immigration',
    SPOKEN_LNG_NAME AS 'Lang', FPL_PRCNTG AS 'FPL', RAC_CODE AS 'RACcode', RAC_NAME AS 'RACname',
    FROM_DATE AS 'FromDate', TO_DATE AS 'ToDate',
    covtime = DATEDIFF(dd,FROM_DATE, CASE WHEN TO_DATE > GETDATE() THEN GETDATE() ELSE TO_DATE END),
    END_REASON AS 'EndReason', COVERAGE_TYPE_IND AS 'Coverage', POSTAL_CODE AS 'Zip',
    ROW_NUMBER() OVER(PARTITION BY MEDICAID_RECIPIENT_ID ORDER BY MEDICAID_RECIPIENT_ID, FROM_DATE DESC, TO_DATE DESC) AS 'Row'
    FROM dbo.vEligibility
    WHERE CAL_YEAR=2014 AND BIRTH_DATE BETWEEN '1997-01-01' AND '2011-12-31'
    ORDER BY MEDICAID_RECIPIENT_ID, FROM_DATE DESC, TO_DATE DESC"
  )
proc.time() - ptm01


# Keep the last row from 2014 for each child
elig2014 <- elig %>%
  group_by(ID2014) %>%
  filter(row_number() == n())


# Select children in the following year to be matched with baseline
elig2015 <-
  sqlQuery(
    db.claims,
    "SELECT DISTINCT MEDICAID_RECIPIENT_ID AS 'ID2015'
    FROM dbo.vEligibility
    WHERE CAL_YEAR = 2015 AND BIRTH_DATE BETWEEN '1997-01-01' AND '2011-12-31'
    GROUP BY MEDICAID_RECIPIENT_ID"
  )


# Match baseline with the following year (only include children present in both years)
eligall <- merge(elig2014, elig2015, by.x = "ID2014", by.y = "ID2015")

# Drop data frames to free up memory
rm("elig2014", "elig2015")


##### Bring in all the relevant claims data #####

# Baseline (2014) hospitalizations and ED visits (any cause)
ptm02 <- proc.time() # Times how long this query takes (~90 secs)
hospED <-
  sqlQuery(
    db.claims,
    "SELECT DISTINCT MEDICAID_RECIPIENT_ID AS 'ID2014',
    SUM(CASE WHEN CAL_YEAR = 2014 AND CLM_TYPE_CID = 31 THEN 1 ELSE 0 END) AS 'hosp',
    SUM(CASE WHEN CAL_YEAR = 2014 AND REVENUE_CODE IN ('0450','0456','0459','0981') THEN 1 ELSE 0 END) AS 'ED',
    SUM(CASE WHEN CAL_YEAR = 2014 AND PLACE_OF_SERVICE = '20 URGENT CARE FAC' THEN 1 ELSE 0 END) AS 'urgent'
    FROM dbo.vClaims
    GROUP BY MEDICAID_RECIPIENT_ID"
  )
proc.time() - ptm02


# Bring in all pharmacy claims from 2014 and 2015
ptm.temp <- proc.time() # Times how long this query takes (~150-250 secs)
pharmall <-
  sqlQuery(
    db.claims,
    "SELECT MEDICAID_RECIPIENT_ID AS 'ID2014', CAL_YEAR, NDC AS 'ndc', NDC_DESC AS 'ndcdesc',
    PRSCRPTN_FILLED_DATE AS 'rxdate', DRUG_DOSAGE AS 'dose'
    FROM dbo.vClaims
    WHERE CAL_YEAR IN (2014, 2015) AND CLM_TYPE_CID = 24
    ORDER BY MEDICAID_RECIPIENT_ID"
  )
proc.time() - ptm.temp


# Limit pharmacy records to only those included children
pharmchild <- semi_join(pharmall, distinct(eligall, ID2014), by = "ID2014") %>%
  mutate(ID2014 = as.factor(ID2014))
# Remove the total pharm data to free up memory
rm("pharmall")


# 2014 and 2015 claims for patients with asthma
ptm03 <- proc.time() # Times how long this query takes (~90 secs)
asthma <-
  sqlQuery(
    db.claims,
    "SELECT MEDICAID_RECIPIENT_ID AS 'ID2014', *
    FROM dbo.vClaims
    WHERE CAL_YEAR IN (2014, 2015)
    AND (PRIMARY_DIAGNOSIS_CODE LIKE '493%' OR PRIMARY_DIAGNOSIS_CODE LIKE 'J45%'
    OR DIAGNOSIS_CODE_2 LIKE '493%' OR DIAGNOSIS_CODE_2 LIKE 'J45%'
    OR DIAGNOSIS_CODE_3 LIKE '493%' OR DIAGNOSIS_CODE_3 LIKE 'J45%'
    OR DIAGNOSIS_CODE_4 LIKE '493%' OR DIAGNOSIS_CODE_4 LIKE 'J45%'
    OR DIAGNOSIS_CODE_5 LIKE '493%' OR DIAGNOSIS_CODE_5 LIKE 'J45%')"
  )
proc.time() - ptm03


# Pull out just those with 2014 claims to set population for prediction model
asthma2014 <- asthma %>%
  filter(CAL_YEAR == 2014) %>%
  distinct(ID2014) %>%
  select(ID2014)



##### Bring in other relevant data #####
# Bring in asthma med list
meds <- read.csv("H:/my documents/Medicaid claims/Asthma/NDC493.csv")
# Set up type of medication
meds <- meds %>%
  mutate(controller = ifelse(category %in% c("antiasthmatic combinations", "antibody inhibitor", "inhaled corticosteroids",
                                             "inhaled steroid combinations", "leukotriene modifiers", "mast cell stablizers",
                                             "methylxanthines"), 1, 0),
         reliever = ifelse(category %in% c("short-acting inhaled beta-2 agonists"), 1, 0))


# Bring in zipcode file and recode
zipgps <- read_dta("H:/my documents/Medicaid claims/Asthma/zipgps.dta")
zipgps <- zipgps %>%
  mutate(region = recode(hpa, "c('Bellevue', 'Bothell/Woodinville', 'Issaquah/Sammamish', 
                         'Kirkland', 'Mercer Isl/Point Cities', 'Redmond/Union Hill') = 1;
                         c('Auburn', 'Burien/Des Moines', 'Federal Way', 'Kent', 'Lower Valley & Upper Sno',
                         'Southeast King County', 'Tukwila/SeaTac', 'Vashon Island') = 2;
                         else = 3", as.factor.result = FALSE),
         hizip = ifelse(zipcode %in% c(98001, 98002, 98022, 98023, 98030, 98042, 98047, 98052, 98057,
                                       98065, 98092, 98112, 98118, 98122, 98144, 98146, 98155, 98178, 98188), 1, 0))


##### Merge all eligible children with asthma claims and total hospital/ED visits #####
asthmachild <- merge(eligall, asthma, by = "ID2014") %>%
  arrange(ID2014, FROM_SRVC_DATE)


# Append all pharma records for children with 1+ asthma claims
pharmasthma <- semi_join(pharmchild, distinct(asthmachild, ID2014), by = "ID2014") %>%
  mutate(ID2014 = as.factor(ID2014)) %>%
  arrange(ID2014, rxdate) # This keeps pharmacy records only for children with asthma claims
asthmachild <- bind_rows(asthmachild, pharmasthma) %>%
  mutate(ID2014 = as.factor(ID2014))
  

# Merge with asthma meds
asthmachild <- mutate(asthmachild, ndc = ifelse(is.na(ndc), NDC, ndc)) # fill in any blank ndc records
asthmachild <- merge(asthmachild, meds, by = "ndc", all.x = TRUE)


# Count up number of baseline (2014) predictors for each child
asthmachild <- asthmachild %>%
  group_by(ID2014) %>%
  mutate(
    # hospitalizations for asthma, any diagnosis
    hospcnt14 = sum(ifelse(CAL_YEAR == 2014 &
                             CLM_TYPE_CID == 31, 1, 0), na.rm = TRUE),
    # hospitalizations for asthma, primary diagnosis
    hospcntprim14 = sum(ifelse(
      CAL_YEAR == 2014 & CLM_TYPE_CID == 31 &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE),
    # ED visits for asthma, any diagnosis
    EDcnt14 = sum(ifelse(
      CAL_YEAR == 2014 & REVENUE_CODE %in% c(0450, 0456, 0459, 0981), 1, 0
    ), na.rm = TRUE),
    # ED visits for asthma, primary diagnosis
    EDcntprim14 = sum(ifelse(
      CAL_YEAR == 2014 & REVENUE_CODE %in% c(0450, 0456, 0459, 0981) &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE),
    # Urgent care visits for asthma, any diagnosis
    urgcnt14 = sum(ifelse(
      CAL_YEAR == 2014 & PLACE_OF_SERVICE == "20 URGENT CARE FAC", 1, 0
    ), na.rm = TRUE),
    # Urgent visits for asthma, primary diagnosis
    urgcntprim14 = sum(ifelse(
      CAL_YEAR == 2014 & PLACE_OF_SERVICE == "20 URGENT CARE FAC" &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE),
    # well-child checks for asthma, any diagnosis
    wellcnt14 = sum(ifelse(CAL_YEAR == 2014 &
                             CLM_TYPE_CID == 27, 1, 0), na.rm = TRUE),
    # well-child checks for asthma, primary diagnosis
    wellcntprim14 = sum(ifelse(
      CAL_YEAR == 2014 & CLM_TYPE_CID == 27 &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE),
    # total number of asthma claims, any diagnosis
    asthmacnt14 = sum(ifelse(CAL_YEAR == 2014, 1, 0), na.rm = TRUE),
    # total number of asthma claims, primary diagnosis
    asmthacntprim14 = sum(ifelse(
      CAL_YEAR == 2014 &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE),
    # Count up number of outcome (2015) measures for each child
    # hospitalizations for asthma, any diagnosis
    hospcnt15 = sum(ifelse(CAL_YEAR == 2015 &
                             CLM_TYPE_CID == 31, 1, 0), na.rm = TRUE),
    # hospitalizations for asthma, primary diagnosis
    hospcntprim15 = sum(ifelse(
      CAL_YEAR == 2015 & CLM_TYPE_CID == 31 &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE),
    # ED visits for asthma, any diagnosis
    EDcnt15 = sum(ifelse(
      CAL_YEAR == 2015 & REVENUE_CODE %in% c(0450, 0456, 0459, 0981), 1, 0
    ), na.rm = TRUE),
    # ED visits for asthma, primary diagnosis
    EDcntprim15 = sum(ifelse(
      CAL_YEAR == 2015 & REVENUE_CODE %in% c(0450, 0456, 0459, 0981) &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE),
    # Urgent care visits for asthma, any diagnosis
    urgcnt15 = sum(ifelse(
      CAL_YEAR == 2015 & PLACE_OF_SERVICE == "20 URGENT CARE FAC", 1, 0
    ), na.rm = TRUE),
    # Urgent visits for asthma, primary diagnosis
    urgcntprim15 = sum(ifelse(
      CAL_YEAR == 2015 & PLACE_OF_SERVICE == "20 URGENT CARE FAC" &
        (
          substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "493" |
            substr(PRIMARY_DIAGNOSIS_CODE, 1, 3) == "J45"
        ),
      1,
      0
    ), na.rm = TRUE)
  ) %>%
arrange(ID2014, CAL_YEAR)


# Calculate asthma medication ratio
tmp.meds <- asthmachild %>%
    group_by(ID2014) %>%
    filter(CAL_YEAR == "2014" &
             (!is.na(controller) | !is.na(reliever))) %>%
    mutate(
      controltot = sum(ifelse(
        CAL_YEAR == 2014 &
          !is.na(CAL_YEAR) & controller == 1 & !is.na(controller),
        1,
        0
      ), na.rm = TRUE),
      relievertot = sum(ifelse(
        CAL_YEAR == 2014 &
          !is.na(CAL_YEAR) & reliever == 1 & !is.na(reliever),
        1,
        0
      ), na.rm = TRUE),
      amr14 = controltot / (controltot + relievertot),
      amr14risk = ifelse(amr14 < 0.5, 1, ifelse(amr14 >= 0.5, 0, NA)),
      # Add in binary classifications of medication use
      relieverhigh6 = ifelse(relievertot >= 6, 1, 0),
      relieverhigh5 = ifelse(relievertot >= 5, 1, 0),
      relieverhigh4 = ifelse(relievertot >= 4, 1, 0),
      relieverhigh3 = ifelse(relievertot >= 3, 1, 0)
    ) %>%
<<<<<<< Updated upstream
    distinct(ID2014, amr14) %>%
    select(ID2014, controltot:relieverhigh3)
=======
    distinct(ID2014, amr14, .keep_all = TRUE) %>%
    select(ID2014, controltot, relievertot, amr14, amr14risk, relieverhigh)
>>>>>>> Stashed changes

  
# Collapse claims data and merge with medication data
asthmarisk <- asthmachild %>%
  distinct(ID2014, .keep_all = TRUE) %>%
  # Keep columns of interest
  select(ID2014, hospcnt14:urgcntprim15)
  

# Merge with just 2014 claimants, total hospitalizations, demogs from eligibility, meds, and zip code risk
asthmarisk <- merge(asthmarisk, asthma2014,  by = "ID2014")
asthmarisk <- merge(asthmarisk, hospED, by = "ID2014", all.x = TRUE)
asthmarisk <- merge(asthmarisk, eligall, by = "ID2014", all.x = TRUE)
asthmarisk <- merge(asthmarisk, tmp.meds, by = "ID2014", all.x = TRUE)
asthmarisk <- merge(asthmarisk, zipgps, by.x = "Zip", by.y = "zipcode", all.x = TRUE)



# Create and recode other variables for analysis
arbwght <- 3 # sets up the arbitrary weight for hospitalizations (compared with ED visits)

asthmarisk <- asthmarisk %>%
  mutate(
    # count of non-asthma-related hospitalizations in 2014
    hospnonasth14 = hosp - hospcnt14,
    # count of non-asthma-related ED visits in 2014
    EDnonasth14 = ED - EDcnt14,
    # weighted count of 2014 (baseline) asthma-related hospital/ED encounters, any diagnosis
    asthmaenc14 = (hospcnt14 * arbwght) + EDcnt14,
    # weighted count of 2015 (outcome) asthma-related hospital/ED encounters, any diagnosis
    asthmaenc15 = (hospcnt15 * arbwght) + EDcnt15,
    # weighted count of 2015 (outcome) asthma-related hospital/ED encounters, primary diagnosis
    asthmaencprim15 = (hospcntprim15 * arbwght) + EDcntprim15,
    # recoded count of 2015 (outcome) hospital-related asthma visits
    hospcnt15.r = recode(hospcnt15, "0 = 0; 1:2 = 1; 3:hi = 2"),
    # recode Hispanic variable
    hisp = recode(Hispanic, "'NOT HISPANIC' = 0; 'HISPANIC' = 1", as.factor.result = FALSE), # the last part ensures the new variable codes as numeric
    # recode gender variable
    female = recode(Gender, "'Female' = 1; 'Male' = 0", as.factor.result = FALSE),
    # recode race variable
    race = recode(Race1, "c('Alaskan Native','American Indian') = 1; 'Asian' = 2; 
                          'Black' = 3; c('Hawaiian', 'Pacific Islander') = 5; 'White' = 6; else = 7",
                              as.factor.result = FALSE),
    # makes Hispanic race category from those with no defined race
    race = replace(race, which(race == 7 & hisp == 1), 4),
    # recodes those with an Asian language and no race to Asian race
    race = replace(race, which(race == 7 & Lang %in% c("Burmese","Chinese","Korean","Vietnamese","Tagalog")), 2),
    # recodes those with Somali language and no race to black race
    race = replace(race, which(race == 7 & Lang == "Somali"), 3),  
    # recodes those with Russian language and no race to white race
    race = replace(race, which(race == 7 & Lang == "Russian"), 6),   
    # recodes those with Spanish language and no race to Hispanic race
    race = replace(race, which(race == 7 & Lang == "Spanish; Castillian"), 4),
    # add in Vietnamese category based on prior experience with asthma programs
    race2 = race,
    race2 = replace(race2, which(Lang == "Vietnamese"), 8),
    # makes race and race2 factor variables and sets white to be reference category
    race = as.factor(race),
    race = relevel(race, ref = 6),
    race2 = as.factor(race2),
    race2 = relevel(race2, ref = 6),
    # extract age from birth year and recode into age groups
    age = 2014 - as.numeric(substr(DOB,1,4)),
    agegrp = cut(age, breaks = c(3, 5, 11, 18), right = FALSE, labels = c(1:3)),
    # recode Federal poverty level into groups
    fplgrp = cut(FPL, breaks = c(1, 133, 199, max(FPL[!is.na(FPL)])), right = FALSE, labels = c(1:3)),
    fplgrp = replace(fplgrp, which(fplgrp == 1 & RACcode == 1203), 1),
    # make outcomes binary
    baseline = ifelse(hospcnt14 > 0 | EDcnt14 > 0 | urgcnt14 > 0, 1, 0),
    baselineprim = ifelse(hospcntprim14 > 0 | EDcntprim14 > 0 | urgcntprim14 > 0, 1, 0),
    outcome = ifelse(hospcnt15 > 0 | EDcnt15 > 0 | urgcnt15 > 0, 1, 0),
    outcomeprim = ifelse(hospcntprim15 > 0 | EDcntprim15 > 0 | EDcntprim15 > 0, 1, 0)
  )




# ANALYSIS ----------------------------------------------------------------

## NB. It is presumed that children with an asthma-related hospitalization or ED visit are at high risk and so are excluded
## from the prediction model

### Using rms package (cannot define as a factor variable in the model so use scored instead)
# Make data frame for prediction comparisons
d <- datadist(asthmarisk)
options(datadist="d")

# Simple model with prior hospitalizations/ED visits, asthma-related well child checks, and demographics
m1 <- lrm(outcome ~ hospnonasth14 + EDnonasth14 + wellcnt14 + scored(agegrp) + female + scored(race) + 
            scored(fplgrp) + hizip, data = asthmarisk, subset = hospcnt14 ==0 & EDcnt14 == 0, x = TRUE, y = TRUE)
m1

# Previous model but including asthma medication variables (can vary relieverhigh from 3 to 6)
m2 <- lrm(outcome ~ hospnonasth14 + EDnonasth14 + wellcnt14 + scored(agegrp) + female + scored(race) + 
            scored(fplgrp) + hizip + amr14risk + relieverhigh3, data = asthmarisk, subset = hospcnt14 ==0 & EDcnt14 == 0,
          x = TRUE, y = TRUE)
m2

p2 <- Predict(m2)
plot(p2, anova = anova(m2), pval = TRUE)


# repeat using glm
m2a <- glm(outcome ~ hospnonasth14 + EDnonasth14 + wellcnt14 + factor(agegrp) + female + factor(race) + 
            factor(fplgrp) + hizip + amr14risk + relieverhigh3, data = asthmarisk, family = "binomial",
          subset = hospcnt14 ==0 & EDcnt14 == 0)

summary(m2a)
p2a <- predict(m2a)
plot(m2a, which = 1)
glm.diag.plots(m2a)

# Compare two models
lrtest(m1, m2)

# Drop FPL due to large # of missing
m3 <- lrm(outcome ~ hospnonasth14 + EDnonasth14 + wellcnt14 + scored(agegrp) + female + scored(race) +
            hizip + amr14risk + relieverhigh6, data = asthmarisk, subset = hospcnt14 ==0 & EDcnt14 == 0, x = TRUE, y = TRUE)
m3

lrtest(m2, m3)


# Look at children with a hosp/ED asthma event in 2014
m4 <- lrm(outcome ~ hospnonasth14 + EDnonasth14 + wellcnt14 + scored(agegrp) + female + scored(race) +
            hizip + amr14risk + relieverhigh6, data = asthmarisk, subset = hospcnt14 > 0 & EDcnt14 > 0, x = TRUE, y = TRUE)
m4

lrtest(m2, m4)


### Assess number of children with each predictor
# Make temp data set to match the children in the model
asthmarisk.tmp <- asthmarisk %>%
  filter(hospcnt14 == 0 & EDcnt14 == 0 & !is.na(hospnonasth14) & !is.na(EDnonasth14) & !is.na(wellcnt14) & 
           !is.na(agegrp) & !is.na(female) & !is.na(race) & !is.na(fplgrp) & !is.na(hizip) & !is.na(amr14risk) & 
           !is.na(relieverhigh6))

table(asthmarisk.tmp$EDnonasth14, useNA = 'always')
table(asthmarisk.tmp$female, useNA = 'always')
table(asthmarisk.tmp$hizip, useNA = 'always')
table(asthmarisk.tmp$amr14risk, useNA = 'always')
<<<<<<< Updated upstream

table(asthmarisk.tmp$relieverhigh6, useNA = 'always')
table(asthmarisk.tmp$relieverhigh5, useNA = 'always')
table(asthmarisk.tmp$relieverhigh4, useNA = 'always')
table(asthmarisk.tmp$relieverhigh3, useNA = 'always')
=======
table(asthmarisk.tmp$relieverhigh, useNA = 'always')

# Look at number of children without hospitalization, ED visit, or urgent care event in 2014
asthmarisk.tmp2 <- asthmarisk %>%
  filter(baseline == 0) %>%
  mutate(EDnonasth14hi = ifelse(EDnonasth14 > 0, 1, 0),
         controlhi = ifelse(controltot > 0, 1, 0),
         afam = ifelse(race == 2, 1, 0),
         riskfact = rowSums(cbind(EDnonasth14hi, relieverhigh, controlhi, afam), na.rm = TRUE))
  
table(asthmarisk.tmp2$EDnonasth14, useNA = 'always')
table(asthmarisk.tmp2$EDnonasth14hi, useNA = 'always')
table(asthmarisk.tmp2$relieverhigh, useNA = 'always')
table(asthmarisk.tmp2$controltot, useNA = 'always')
table(asthmarisk.tmp2$controlhi, useNA = 'always')
table(asthmarisk.tmp2$race, useNA = 'always')
table(asthmarisk.tmp2$afam, useNA = 'always')

table(asthmarisk.tmp2$riskfact, useNA = 'always')
>>>>>>> Stashed changes
