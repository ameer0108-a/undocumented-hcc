# Reference files

| File | What it is | Source |
|---|---|---|
| `snomed_icd10cm_crosswalk.csv` | SNOMED CT disorder codes Synthea emits, mapped to ICD-10-CM | Built by hand for this project. Every ICD-10-CM code checked against the April 1, 2026 code set. `map_note` explains non-obvious picks. |
| `cms_v28_dx_to_hcc_2026.csv` | ICD-10-CM (no dots) to CMS-HCC V28 | CMS 2026 midyear/final ICD-10 mappings, V28 rows only |
| `cms_v28_hcc_labels.csv` | V28 HCC labels | CMS 2026 model software |
| `cms_v28_hierarchies.csv` | V28 hierarchy pairs (parent wins over child) | CMS 2026 model software |
| `cms_v28_coefficients_cna.csv` | V28 community, non-dual, aged relative factors | CMS 2026 model software |

The four CMS files were pulled from the copy of the 2026 CMS files that ships inside the open-source `hccinfhir` Python package (version 0.4.0), because cms.gov wasn't reachable from the machine that built this. To check them against the originals, download "2026 Midyear/Final ICD-10-Mappings" and "2026 Midyear/Final Model Software" from
https://www.cms.gov/medicare/payment/medicare-advantage-rates-statistics/risk-adjustment/2026-model-software-icd-10-mappings
