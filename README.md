# live-artifact

Working files for Tradex Trading & Contracting.

- `tradex-flow.html`: the project flow from cost estimate to customer and subcontractor progress billing, with owner, Odoo document and control for each step, plus a monthly progress log per project.
- `tradex-estimate.html` (served at `/estimate`): project cost estimates. Keep a price list of materials and subcontractor items (typed in or imported from Excel/CSV), build the cost of one indoor unit, multiply by the number of units, add overhead (15%) and indirect cost (35%) on direct cost, and price for a 20% margin on the sales price. Rates can be changed per estimate, and each estimate exports to Excel with live formulas.

## Using it

Open `tradex-flow.html` or `tradex-estimate.html` in a browser and sign in (one account works for both). The first time, choose **Create an account**, confirm the email Supabase sends, then sign in. Only emails on the editors list can see or change the data.

Everything is stored in the Supabase project "live artifact" (eu-central-1). Each change is saved when you press Save and logged with who made it and when; open **History** on a step to see its past versions.
