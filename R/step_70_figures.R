# step_70_figures.R
# Figures for the write-up and slides. All saved as 16:9 PNGs in output/figures.
# Colors: three fixed series colors (one per rule tier) that stay distinguishable
# for common color vision deficiencies. Text is always dark gray, never the series color.

Sys.setenv(TZ = "UTC")
source("R/utils.R"); source("R/evaluate.R")
suppressPackageStartupMessages({ library(ggplot2) })

con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)
q <- function(sql) as.data.table(DBI::dbGetQuery(con, sql))
dir.create("output/figures", showWarnings = FALSE, recursive = TRUE)

ink <- "#0b0b0b"; ink2 <- "#52514e"; muted <- "#898781"; grid_col <- "#e1e0d9"; surface <- "#fcfcfb"
tier_cols <- c("Single lab" = "#eb6834", "Guideline (ADA/KDIGO)" = "#2a78d6", "Revalidation hybrid" = "#1baf7a")
two_cols  <- c("Raw Synthea" = "#eb6834", "Lab model" = "#2a78d6")

theme_proj <- function() {
  theme_minimal(base_size = 15, base_family = "sans") +
    theme(plot.background = element_rect(fill = surface, colour = NA),
          panel.grid.major.x = element_blank(), panel.grid.minor = element_blank(),
          panel.grid.major.y = element_line(colour = grid_col, linewidth = 0.4),
          axis.text = element_text(colour = ink2), axis.title = element_text(colour = ink2),
          plot.title = element_text(colour = ink, face = "bold", size = 18),
          plot.subtitle = element_text(colour = ink2, size = 13),
          plot.caption = element_text(colour = muted, size = 10, hjust = 0),
          strip.text = element_text(colour = ink, face = "bold", hjust = 0),
          legend.position = "top", legend.justification = "left",
          legend.text = element_text(colour = ink2), legend.title = element_blank(),
          plot.margin = margin(16, 20, 12, 16))
}
save_fig <- function(p, name) ggsave(file.path("output/figures", paste0(name, ".png")), p,
                                     width = 12, height = 6.75, dpi = 160, bg = surface)

perf <- fread("output/tables/performance_by_scenario_tier.csv")
perf[, tier_label := factor(tier_label, levels = names(tier_cols))]
perf[, family := factor(family, levels = c("DM", "CKD", "All 4 HCCs"),
                        labels = c("Diabetes (HCC 38)", "CKD (HCC 327-329)", "All 4 HCCs"))]

# ---------------------------------------------------------------- 1. raw vs model labs
labs <- q("
  select l.scenario, l.lab, l.value, t.dm_true, t.ckd_stage_coded,
         ref.egfr_ckd_epi_2021(l.value, date_part('year', age(l.draw_date, c.birth_date))::int, c.sex) as egfr
  from study.lab_value l join study.truth t using (patient_id) join study.cohort c using (patient_id)
  where l.scenario in ('raw', 'calibrated') and l.lab in ('a1c', 'creatinine')")
labs[, source := fifelse(scenario == "raw", "Raw Synthea", "Lab model")]
labs[, source := factor(source, levels = names(two_cols))]

a1c <- labs[lab == "a1c" & dm_true == TRUE]
p1a <- ggplot(a1c, aes(value, fill = source)) +
  geom_histogram(binwidth = 0.25, boundary = 0, colour = surface, linewidth = 0.3) +
  facet_wrap(~source, ncol = 1, scales = "free_y") +
  geom_vline(xintercept = c(4, 6.5), colour = ink2, linetype = "dashed", linewidth = 0.4) +
  geom_text(data = data.table(source = factor("Raw Synthea", levels = names(two_cols)), x = c(4.08, 6.58),
                              label = c("Under 4.0% is not\nphysiologically possible", "6.5%: ADA cutoff")),
            aes(x = x, y = Inf, label = label), inherit.aes = FALSE, hjust = 0, vjust = 1.3,
            colour = ink2, size = 3.6, lineheight = 0.9) +
  scale_fill_manual(values = two_cols, guide = "none") +
  coord_cartesian(xlim = c(2, 11)) +
  labs(title = "HbA1c in patients who truly have diabetes",
       subtitle = "Synthea's drug effect pushes over half of diabetics' results under 4%, so a 6.5% rule misses most of them",
       x = "HbA1c (%)", y = "Lab draws") + theme_proj()
save_fig(p1a, "fig1a_a1c_raw_vs_model")

cr <- labs[lab == "creatinine" & ckd_stage_coded == 0]
cr[, egfr_c := pmin(egfr, 130)]
p1b <- ggplot(cr, aes(egfr_c, fill = source)) +
  geom_histogram(binwidth = 5, boundary = 0, colour = surface, linewidth = 0.3) +
  facet_wrap(~source, ncol = 1, scales = "free_y") +
  geom_vline(xintercept = 60, colour = ink2, linetype = "dashed", linewidth = 0.4) +
  geom_text(data = data.table(source = factor("Raw Synthea", levels = names(two_cols))),
            aes(x = 61, y = Inf, label = "eGFR 60: KDIGO cutoff"), inherit.aes = FALSE, hjust = 0, vjust = 1.3,
            colour = ink2, size = 3.6) +
  scale_fill_manual(values = two_cols, guide = "none") +
  labs(title = "eGFR in patients with no kidney disease code",
       subtitle = "Raw Synthea hard-codes creatinine at 2.5 to 3.5 in unrelated modules, which looks like stage 4 CKD",
       x = "eGFR from creatinine (CKD-EPI 2021, capped at 130)", y = "Lab draws") + theme_proj()
save_fig(p1b, "fig1b_egfr_raw_vs_model")

# ---------------------------------------------------------------- 2. PPV vs alert burden
main <- perf[scenario == "calibrated"]
p2 <- ggplot(main, aes(alerts_per_100, ppv, colour = tier_label)) +
  geom_errorbar(aes(ymin = ppv_lo, ymax = ppv_hi), width = 0, linewidth = 0.8) +
  geom_point(size = 3.5, stroke = 1.5, fill = surface, shape = 21) +
  geom_text(data = main[tier == "t1"], aes(label = sprintf("%.2f", ppv)), colour = ink, nudge_x = 0.4, hjust = 0, size = 3.8) +
  geom_text(data = main[tier == "t2"], aes(label = sprintf("%.2f", ppv)), colour = ink, nudge_x = -0.4, hjust = 1, size = 3.8) +
  geom_text(data = main[tier == "t3"], aes(label = sprintf("%.2f", ppv)), colour = ink, nudge_x = 0.4, hjust = 0, size = 3.8) +
  facet_wrap(~family, scales = "free_x") +
  scale_colour_manual(values = tier_cols) +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  scale_x_continuous(expand = expansion(mult = c(0.35, 0.35))) +
  labs(title = "Fewer alerts, and more of them are right",
       subtitle = "PPV with 95% Wilson interval vs. alerts per 100 cohort patients (main scenario)",
       x = "Alerts per 100 patients", y = "PPV") + theme_proj()
save_fig(p2, "fig2_ppv_vs_alert_burden")

# ---------------------------------------------------------------- 3. access gap
gap <- fread("output/tables/access_gap_by_visit_band.csv")[scenario == "calibrated" & family == "All 4 HCCs"]
gap[, tier_label := factor(TIER_LABELS[tier], levels = names(tier_cols))]
gap[, visit_band := factor(visit_band, levels = c("2 or fewer", "3 to 5", "6 or more"))]
p3 <- ggplot(gap, aes(visit_band, sensitivity, fill = tier_label)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.72, colour = surface, linewidth = 0.6) +
  geom_errorbar(aes(ymin = sens_lo, ymax = sens_hi), position = position_dodge(width = 0.8),
                width = 0, colour = ink2, linewidth = 0.5) +
  geom_text(aes(y = 0.02, label = sprintf("%.2f", sensitivity)), position = position_dodge(width = 0.8),
            vjust = 0, colour = "white", size = 3.6, fontface = "bold") +
  scale_fill_manual(values = tier_cols) +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  labs(title = "The rules miss the people who come in least",
       subtitle = "Sensitivity for masked conditions by office visit days per year (all 4 HCCs, main scenario)",
       x = "Office visit days per year", y = "Sensitivity") + theme_proj()
save_fig(p3, "fig3_access_gap")

# ---------------------------------------------------------------- 4. PPV vs masking rate
sweep <- fread("output/tables/ppv_by_mask_rate.csv")[family == "All 4 HCCs"]
sweep[, tier_label := factor(TIER_LABELS[tier], levels = names(tier_cols))]
p4 <- ggplot(sweep, aes(mask_rate, ppv, colour = tier_label)) +
  geom_ribbon(aes(ymin = ppv_lo, ymax = ppv_hi, fill = tier_label), alpha = 0.12, colour = NA) +
  geom_line(linewidth = 1) + geom_point(size = 2.5) +
  scale_colour_manual(values = tier_cols) + scale_fill_manual(values = tier_cols, guide = "none") +
  scale_x_continuous(labels = scales::percent) +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  labs(title = "PPV depends on how much is actually undocumented",
       subtitle = "Same rules, same labs; only the share of true cases hidden from the chart changes",
       x = "Share of true cases masked", y = "PPV (all 4 HCCs)") + theme_proj()
save_fig(p4, "fig4_ppv_vs_mask_rate")

# ---------------------------------------------------------------- 5. RAF
raf <- main[family == "All 4 HCCs", .(tier_label, Recovered = recovered_raf, `Unsupported (false positive)` = false_raf)]
raf <- melt(raf, id.vars = "tier_label", variable.name = "kind", value.name = "raf")
masked_total <- main[family == "All 4 HCCs", masked_raf][1]
p5 <- ggplot(raf, aes(tier_label, raf, fill = kind)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.72, colour = surface, linewidth = 0.6) +
  geom_hline(yintercept = masked_total, colour = ink2, linetype = "dashed", linewidth = 0.4) +
  annotate("text", x = 0.5, y = masked_total, label = sprintf("Masked RAF: %.1f", masked_total),
           hjust = 0, vjust = -0.5, colour = ink2, size = 3.8) +
  geom_text(aes(label = sprintf("%.1f", raf)), position = position_dodge(width = 0.8), vjust = -0.4,
            colour = ink, size = 3.8) +
  scale_fill_manual(values = c("Recovered" = "#2a78d6", "Unsupported (false positive)" = "#eb6834")) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(title = "RAF recovered vs. RAF with no clinical support",
       subtitle = "Sum of V28 community, non-dual, aged coefficients across the cohort (main scenario)",
       x = NULL, y = "Total RAF") + theme_proj()
save_fig(p5, "fig5_raf_recovery")

cat("step 70 done\n")
