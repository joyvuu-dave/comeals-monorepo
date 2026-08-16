const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");

// The calendar month sweep: render every month of 2024-2028 and check
// the grid's structure against plain arithmetic. Five years covers
// both daylight-saving transitions each year, a leap February, and
// months starting on every weekday.
//
// This test exists because of a real escape: the dayjs localizer
// walked the month grid in 24-hour steps, so a month containing the
// end of daylight saving (a 25-hour day) rendered every date under
// the wrong weekday. It sat in production for months because no test
// ever rendered such a month — the goldens only showed January.
//
// The timezone is pinned to the community's (Pacific), and that is
// load-bearing: a viewer in UTC has no DST, so a DST bug is
// invisible there. CI runs in UTC; without this line the sweep would
// prove nothing.
test.use({ timezoneId: "America/Los_Angeles" });

// The grid a correct calendar must show for year/monthIndex: cell
// labels in order, with off-range (gray) cells marked by "*".
function expectedGrid(year, monthIndex) {
  const first = new Date(year, monthIndex, 1);
  const startCol = first.getDay(); // 0 = Sunday, the grid's first column
  const daysInMonth = new Date(year, monthIndex + 1, 0).getDate();
  const daysInPrevMonth = new Date(year, monthIndex, 0).getDate();
  const weeks = Math.ceil((startCol + daysInMonth) / 7);

  const cells = [];
  for (let i = 0; i < weeks * 7; i++) {
    const day = i - startCol + 1;
    if (day < 1) {
      cells.push(String(daysInPrevMonth + day).padStart(2, "0") + "*");
    } else if (day > daysInMonth) {
      cells.push(String(day - daysInMonth).padStart(2, "0") + "*");
    } else {
      cells.push(String(day).padStart(2, "0"));
    }
  }

  const rows = [];
  for (let w = 0; w < weeks; w++) {
    rows.push(cells.slice(w * 7, w * 7 + 7).join(" "));
  }
  return rows;
}

async function actualGrid(page) {
  return page.$$eval(".rbc-month-row", (rowEls) =>
    rowEls.map((row) =>
      Array.from(row.querySelectorAll(".rbc-date-cell"))
        .map(
          (c) =>
            c.textContent.trim() +
            (c.classList.contains("rbc-off-range") ? "*" : ""),
        )
        .join(" "),
    ),
  );
}

test("every month of 2024-2028 renders the correct grid", async ({
  page,
  context,
}) => {
  // 60 months of navigation in one page session; well past the
  // default 30s.
  test.setTimeout(240000);

  await setupAuthenticatedPage(page, context);
  await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));
  await page.goto("/calendar/all/2024-01-15/");
  await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

  for (let year = 2024; year <= 2028; year++) {
    for (let monthIndex = 0; monthIndex < 12; monthIndex++) {
      const monthName = new Date(year, monthIndex, 1).toLocaleString("en-US", {
        month: "long",
      });
      const title = `${monthName} ${year}`;

      // The header names the month we expect before the grid is read.
      await expect(page.locator("h2", { hasText: title })).toBeVisible();

      // Poll: the header updates a frame before the grid repaints
      // (see MonthNavHeader in calendar/show.jsx), so the first read
      // can still see the previous month.
      await expect
        .poll(() => actualGrid(page), { message: `grid for ${title}` })
        .toEqual(expectedGrid(year, monthIndex));

      const last = year === 2028 && monthIndex === 11;
      if (!last) {
        await page.getByLabel("Goto Next Month").click();
        // WebKit enforces Safari's real limit of 100 history state
        // writes per 10 seconds, and one month navigation makes two:
        // react-router calls pushState for the new URL and then
        // replaceState (measured by wrapping both methods). So the
        // loop must average more than 200 ms per month, and the old
        // 150 ms pause left the difference to test overhead — enough
        // on CI, not on a fast machine (failed locally 2026-08-16).
        // 400 ms caps the rate at 5 writes per second, half the
        // budget, no matter how fast the machine is.
        await page.waitForTimeout(400);
      }
    }
  }
});
