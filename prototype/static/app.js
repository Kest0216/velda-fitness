/**
 * PARCHMENT & INK — PERSONAL WORKOUT & RECIPE LEDGER
 * Minimalist negative-space prototype with warm borderless clickables,
 * swipeable recipe tabs, dropdown filters, and 2-font / 3-size hierarchy.
 */

const AppState = {
  activeView: 'workouts', // 'workouts' | 'recipes' | 'vault'
  navFolded: false,
  todayDate: '',
  todayDow: 0,
  selectedDow: 0,
  selectedDate: '',
  todayCompletionPct: 0,
  daySummaries: [],
  workout: null,
  recipes: { saved: [], discover: [] },
  storage: null,

  // Workout inline UI state
  editRoutineMode: false,
  openVideos: {}, // exercise_id -> boolean
  openTrends: {}, // exercise_id -> boolean
  pickerQuery: '',
  pickerResults: [],
  pickerOpen: false,
  customVideoFilename: '',

  // Recipes inline UI state
  recipeTab: 'saved', // 'saved' | 'discover'
  mealFilter: 'All', // 'All' | 'Breakfast' | 'Lunch' | 'Dinner' | 'Snacks'
  dietaryFilters: [], // ['High-Protein', 'Gluten-Free', ...]
  openDropdown: null, // 'meal' | 'dietary' | null
  expandedRecipeId: null,
  discoverQuery: '',
  isDiscovering: false,
  discoverError: '',
  pendingPhotoRecipeId: null,
};

const MEAL_OPTIONS = ['All', 'Breakfast', 'Lunch', 'Dinner', 'Snacks'];
const DIETARY_OPTIONS = [
  'High-Protein',
  'Gluten-Free',
  'Dairy-Free',
  'Nut-Free',
  'Egg-Free',
  'Soy-Free',
  'Vegetarian',
];

const phoneScreen = document.getElementById('phoneScreen');
const viewport = document.getElementById('appContentViewport');
const rightNavLineup = document.getElementById('rightNavLineup');
const navFoldHandle = document.getElementById('navFoldHandle');
const foldedEdgeTab = document.getElementById('foldedEdgeTab');
const btnRefreshLedger = document.getElementById('btnRefreshLedger');
const dailyProgressFill = document.getElementById('dailyProgressFill');
const dailyProgressPct = document.getElementById('dailyProgressPct');
const inkToast = document.getElementById('inkToast');
const navButtons = document.querySelectorAll('.nav-item-btn[data-view]');
const photoInput = document.getElementById('recipePhotoFileInput');

let toastTimer = null;
let pickerSearchTimer = null;

function esc(val) {
  return String(val ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function showToast(msg) {
  inkToast.textContent = msg;
  inkToast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => inkToast.classList.remove('show'), 2300);
}

function formatBytes(bytes) {
  const b = Number(bytes || 0);
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`;
  if (b < 1024 * 1024 * 1024) return `${(b / (1024 * 1024)).toFixed(2)} MB`;
  return `${(b / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

function getWeightUnit() {
  return AppState.storage?.settings?.weight_unit || 'lbs';
}

function updateHeaderDateGreeting() {
  const now = new Date();
  const hr = now.getHours();
  const greeting = hr < 12 ? 'GOOD MORNING' : hr < 18 ? 'GOOD AFTERNOON' : 'GOOD EVENING';
  document.getElementById('greetingText').textContent = greeting;

  const days = ['SUNDAY', 'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY'];
  const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
  document.getElementById('dateDayLine').textContent = days[now.getDay()];
  document.getElementById('dateFullLine').textContent = `${now.getDate()} ${months[now.getMonth()]} ${now.getFullYear()}`;
}

function localIsoDate(dateObj) {
  const y = dateObj.getFullYear();
  const m = String(dateObj.getMonth() + 1).padStart(2, '0');
  const d = String(dateObj.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function isoDateForDowInCurrentWeek(dow) {
  const now = new Date();
  const currentDow = (now.getDay() + 6) % 7;
  const diff = dow - currentDow;
  const target = new Date(now.getFullYear(), now.getMonth(), now.getDate() + diff);
  return localIsoDate(target);
}

function updateTopProgressBar(pct) {
  const clamped = Math.min(100, Math.max(0, Number(pct ?? AppState.todayCompletionPct ?? 0)));
  dailyProgressFill.style.width = `${clamped}%`;
  dailyProgressPct.textContent = `${clamped}%`;
}

function setNavFolded(folded) {
  AppState.navFolded = folded;
  if (folded) {
    rightNavLineup.classList.add('folded');
    rightNavLineup.classList.remove('show-hints');
    foldedEdgeTab.classList.add('visible');
    viewport.classList.remove('nav-open');
  } else {
    rightNavLineup.classList.remove('folded');
    foldedEdgeTab.classList.remove('visible');
    viewport.classList.add('nav-open');
  }
}

function updateActiveNavIndicator() {
  navButtons.forEach((btn) => {
    const view = btn.getAttribute('data-view');
    btn.classList.toggle('active', view === AppState.activeView);
  });
}

function triggerInkWriteAnimation() {
  const lines = viewport.querySelectorAll('.ink-write-line');
  const strokes = viewport.querySelectorAll('.ink-stroke-draw');

  lines.forEach((el) => {
    el.classList.remove('ink-instant');
    el.classList.remove('ink-revealed');
    void el.offsetWidth;
  });

  strokes.forEach((svgEl) => {
    svgEl.classList.remove('ink-instant');
    svgEl.classList.remove('ink-drawn');
    try {
      if (typeof svgEl.getTotalLength === 'function') {
        const len = Math.ceil(svgEl.getTotalLength()) + 4;
        svgEl.style.setProperty('--dash-len', len);
      }
    } catch (_) {}
    void svgEl.offsetWidth;
  });

  lines.forEach((el, idx) => {
    const delay = (Math.min(idx, 14) * 0.05).toFixed(3) + 's';
    el.style.setProperty('--write-delay', delay);
    el.style.setProperty('--write-dur', '0.52s');
    el.classList.add('ink-revealed');
  });

  strokes.forEach((svgEl, idx) => {
    const delay = (0.06 + Math.min(idx, 10) * 0.07).toFixed(3) + 's';
    svgEl.style.setProperty('--draw-delay', delay);
    svgEl.style.setProperty('--draw-dur', '0.72s');
    svgEl.classList.add('ink-drawn');
  });
}

async function apiFetch(url, options = {}) {
  const res = await fetch(url, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(data.message || data.error || `Request failed (${res.status})`);
    err.code = data.error;
    throw err;
  }
  return data;
}

/* --------------------------------------------------------------------------
 * WORKOUTS VIEW (No separator lines, no pill borders, negative space)
 * -------------------------------------------------------------------------- */

function renderTrendlineSvg(prog, unit) {
  const sessions = prog.sessions || [];
  if (sessions.length < 2) {
    return `
      <div class="mt-3 soft-panel t-sm text-[#4a443d]">
        Log at least 2 sessions to plot total volume trendline (${esc(prog.latest_volume)} ${prog.metric_unit === 'reps' ? 'reps' : unit + '·reps'} logged so far).
      </div>
    `;
  }

  const w = 260;
  const h = 72;
  const padX = 16;
  const padY = 14;
  const ys = sessions.map((s) => s.volume);
  const ts = prog.trend_points || ys;
  const allVals = ys.concat(ts);
  let minV = Math.min(...allVals);
  let maxV = Math.max(...allVals);
  if (maxV - minV < 1) {
    minV = Math.max(0, minV - 10);
    maxV = maxV + 10;
  }
  const span = maxV - minV;

  const toX = (i) => padX + (i / Math.max(1, sessions.length - 1)) * (w - padX * 2);
  const toY = (v) => h - padY - ((v - minV) / span) * (h - padY * 2);

  const actualPath = ys.map((v, i) => `${i === 0 ? 'M' : 'L'} ${toX(i).toFixed(1)} ${toY(v).toFixed(1)}`).join(' ');
  const trendPath = `M ${toX(0).toFixed(1)} ${toY(ts[0]).toFixed(1)} L ${toX(sessions.length - 1).toFixed(1)} ${toY(ts[ts.length - 1]).toFixed(1)}`;
  const unitLabel = prog.metric_unit === 'reps' ? 'reps' : `${unit} vol`;

  const verdict =
    prog.status === 'yes'
      ? `Moving more weight over time (+${prog.delta_pct}%)`
      : prog.status === 'flat'
      ? `Volume holding steady (${prog.delta_pct >= 0 ? '+' : ''}${prog.delta_pct}%)`
      : `Volume dipped (${prog.delta_pct}%) across last ${sessions.length} sessions`;

  return `
    <div class="mt-3 soft-panel">
      <div class="flex items-center justify-between t-sm uppercase tracking-[0.12em] text-[#4a443d] mb-1">
        <span>${esc(unitLabel)}</span>
        <span>${sessions.length} Sessions</span>
      </div>
      <svg viewBox="0 0 ${w} ${h + 16}" class="w-full h-[84px] overflow-visible">
        <line x1="${padX}" y1="${h - padY}" x2="${w - padX}" y2="${h - padY}" stroke="#191715" stroke-opacity="0.14" stroke-width="1" />
        <path d="${trendPath}" fill="none" stroke="#4a443d" stroke-width="1.2" stroke-dasharray="3 3" />
        <path d="${actualPath}" fill="none" stroke="#191715" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" />
        ${sessions
          .map((s, i) => {
            const x = toX(i).toFixed(1);
            const y = toY(s.volume).toFixed(1);
            const isLast = i === sessions.length - 1;
            const mmdd = s.date.slice(5).replace('-', '/');
            return `
              <circle cx="${x}" cy="${y}" r="${isLast ? 3.2 : 2.2}" fill="${isLast ? '#191715' : '#d8c8ae'}" stroke="#191715" stroke-width="1.3" />
              ${i === 0 || isLast ? `<text x="${x}" y="${Number(y) - 6}" text-anchor="middle" fill="#191715" font-size="8.5" font-family="Montserrat, sans-serif" font-weight="600">${Math.round(s.volume)}</text>` : ''}
              <text x="${x}" y="${h + 10}" text-anchor="middle" fill="#4a443d" font-size="8" font-family="Montserrat, sans-serif">${mmdd}</text>
            `;
          })
          .join('')}
      </svg>
      <div class="ink-serif italic t-md text-[#191715] mt-1">${esc(verdict)}</div>
    </div>
  `;
}

function renderProgressionBadge(ex, unit) {
  const p = ex.progression || { status: 'baseline', delta_pct: 0, latest_volume: 0, metric_unit: 'vol' };
  let label = 'Baseline';
  if (p.status === 'yes') {
    label = `Moving More · Yes ↑ ${p.delta_pct > 0 ? '+' + p.delta_pct : p.delta_pct}%`;
  } else if (p.status === 'no') {
    label = `Moving More · No ↓ ${p.delta_pct}%`;
  } else if (p.status === 'flat') {
    label = `Moving More · No → ${p.delta_pct >= 0 ? '+' + p.delta_pct : p.delta_pct}%`;
  } else if ((p.sessions || []).length === 1) {
    label = 'Baseline · 1 Session';
  }

  const volStr =
    p.latest_volume > 0
      ? p.metric_unit === 'reps'
        ? `${Math.round(p.latest_volume)} reps`
        : `${Math.round(p.latest_volume).toLocaleString()} ${unit}`
      : 'No sets';

  return `
    <div class="flex items-center justify-between gap-2 mt-2">
      <button
        type="button"
        onclick="toggleTrend('${esc(ex.id)}')"
        class="prog-badge ${esc(p.status)}"
        title="Inspect session volume trendline"
      >${esc(label)}</button>
      <span class="t-sm tracking-[0.06em] uppercase text-[#4a443d] tabular-nums">${esc(volStr)}</span>
    </div>
  `;
}

function renderWorkoutsView() {
  const wk = AppState.workout;
  if (!wk) {
    return `<div class="pt-6 ink-serif italic t-md text-[#4a443d]">Opening training ledger…</div>`;
  }

  const unit = getWeightUnit();
  const isToday = AppState.selectedDow === AppState.todayDow;

  return `
    <div class="space-y-6 pt-2">
      <!-- 7-Day Routine Strip (Negative space, warm active wash) -->
      <div class="ink-write-line flex items-center justify-between gap-1">
        ${AppState.daySummaries
          .map(
            (d) => `
          <button
            type="button"
            onclick="selectWorkoutDay(${d.day_of_week})"
            class="day-chip ${d.day_of_week === AppState.selectedDow ? 'active' : ''}"
          >
            <span>${esc(d.day_short)}</span>
            <span class="day-chip-dot" style="opacity: ${d.exercise_count > 0 ? 1 : 0.22}"></span>
          </button>
        `
          )
          .join('')}
      </div>

      <!-- Day Routine Title + Edit Toggle -->
      <div class="ink-write-line flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="tracked-caps t-sm text-[#4a443d]">
            ${esc(wk.day_full_name)}${isToday ? ' · Today' : ''} · ${wk.total_exercises === 0 ? 'Rest' : `${wk.completed_exercises}/${wk.total_exercises}`}
          </div>
          ${
            AppState.editRoutineMode
              ? `
            <form onsubmit="saveRoutineTitle(event)" class="flex items-center gap-2 mt-1.5">
              <input id="routineTitleInput" type="text" class="ink-input flex-1 t-md" value="${esc(wk.title)}" maxlength="48" />
              <button type="submit" class="warm-action is-active">Save</button>
            </form>
          `
              : `
            <h1 class="ink-serif italic t-lg text-[#191715] mt-1 truncate">
              ${esc(wk.title)}
            </h1>
          `
          }
        </div>
        <button
          type="button"
          onclick="toggleEditRoutine()"
          class="warm-action shrink-0 mt-1 ${AppState.editRoutineMode ? 'is-active' : ''}"
        >${AppState.editRoutineMode ? 'Done' : 'Edit'}</button>
      </div>

      <!-- Routine Exercises (Separated purely by negative space) -->
      ${
        wk.exercises.length === 0
          ? `
        <div class="ink-write-line py-8 text-center space-y-2">
          <p class="ink-serif italic t-lg text-[#191715]">Rest &amp; Recovery Day</p>
          <p class="t-sm tracking-[0.08em] uppercase text-[#4a443d]">Add any movement below to train today</p>
        </div>
      `
          : `
        <div class="space-y-7 pt-1">
          ${wk.exercises
            .map((ex) => {
              const videoOpen = !!AppState.openVideos[ex.id];
              const trendOpen = !!AppState.openTrends[ex.id];
              return `
              <article class="ink-write-line">
                <div class="flex items-start justify-between gap-2">
                  <div class="min-w-0">
                    <h2 class="ink-serif t-lg font-semibold text-[#191715]">
                      ${esc(ex.name)}
                    </h2>
                    <div class="t-sm tracking-[0.1em] uppercase text-[#4a443d] mt-0.5">
                      ${esc(ex.muscle_hint)}${ex.is_custom ? ' · Custom' : ''}
                    </div>
                  </div>
                  <div class="flex items-center gap-1.5 shrink-0">
                    ${
                      ex.video_url
                        ? `
                      <button
                        type="button"
                        onclick="toggleExerciseVideo('${esc(ex.id)}')"
                        class="warm-action ${videoOpen ? 'is-active' : ''}"
                      >${videoOpen ? 'Hide' : '▶ Film'}</button>
                    `
                        : ''
                    }
                    ${
                      AppState.editRoutineMode
                        ? `
                      <button
                        type="button"
                        onclick="removeExerciseFromDay('${esc(ex.id)}')"
                        class="warm-icon-btn t-md"
                        title="Remove from day"
                      >×</button>
                    `
                        : ''
                    }
                  </div>
                </div>

                ${renderProgressionBadge(ex, unit)}

                ${
                  videoOpen && ex.video_url
                    ? `
                  <div class="movekit-video-wrap">
                    <video
                      class="movekit-video"
                      src="${esc(ex.video_url)}"
                      autoplay
                      loop
                      muted
                      playsinline
                      controls
                    ></video>
                  </div>
                `
                    : ''
                }

                ${trendOpen ? renderTrendlineSvg(ex.progression, unit) : ''}

                <!-- Working Sets (Reps x Weight only) -->
                <div class="mt-3 space-y-2">
                  ${ex.sets
                    .map(
                      (s) => `
                    <div class="flex items-center gap-2 t-md">
                      <span class="t-sm font-medium tabular-nums text-[#4a443d] w-5">0${s.set_number}</span>
                      <input
                        type="number"
                        inputmode="numeric"
                        min="0"
                        max="999"
                        value="${s.reps}"
                        onchange="updateSetField(${s.id}, '${esc(ex.id)}', this.value, null, ${s.completed})"
                        class="ink-num-input"
                        aria-label="Reps"
                      />
                      <span class="t-sm uppercase tracking-[0.06em] text-[#4a443d]">×</span>
                      <input
                        type="number"
                        inputmode="decimal"
                        step="any"
                        min="0"
                        max="2000"
                        value="${s.weight}"
                        onchange="updateSetField(${s.id}, '${esc(ex.id)}', null, this.value, ${s.completed})"
                        class="ink-num-input"
                        aria-label="Weight"
                      />
                      <span class="t-sm uppercase tracking-[0.06em] text-[#4a443d]">${esc(unit)}</span>

                      <div class="ml-auto flex items-center gap-2">
                        <button
                          type="button"
                          onclick="toggleSetComplete(${s.id}, '${esc(ex.id)}', ${s.reps}, ${s.weight}, ${!s.completed})"
                          class="ink-checkbox-box"
                          aria-label="Toggle set completion"
                        >
                          <svg width="16" height="16" viewBox="0 0 18 18" fill="none">
                            <path d="M2.5 2.8 L15.3 2.5 L15.6 15.4 L2.6 15.2 Z" stroke="#191715" stroke-width="1.3" stroke-linejoin="round" />
                            ${s.completed ? `<path d="M4.6 9.4 L7.8 12.6 L14.2 5.2" stroke="#191715" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" />` : ''}
                          </svg>
                        </button>
                        <button
                          type="button"
                          onclick="deleteWorkoutSet(${s.id})"
                          class="warm-icon-btn t-md"
                          title="Delete set"
                        >×</button>
                      </div>
                    </div>
                  `
                    )
                    .join('')}

                  <div class="pt-1.5">
                    <button
                      type="button"
                      onclick="addWorkingSet('${esc(ex.id)}')"
                      class="warm-action"
                    >+ Add Set</button>
                  </div>
                </div>
              </article>
            `;
            })
            .join('')}
        </div>
      `
      }

      <!-- Inline Fuzzy Search & Custom Exercise Picker -->
      <div class="ink-write-line pt-3 space-y-2.5">
        <div class="tracked-caps t-sm text-[#4a443d]">Add Movement to ${esc(wk.day_name)}</div>
        <div class="flex items-center gap-2">
          <input
            id="exercisePickerInput"
            type="text"
            class="ink-input flex-1"
            value="${esc(AppState.pickerQuery)}"
            placeholder="Fuzzy search 588 MoveKit or type custom..."
            onfocus="openExercisePicker()"
            oninput="handleExerciseSearch(this.value)"
          />
          <button
            id="exercisePickerCloseBtn"
            type="button"
            onclick="closeExercisePicker()"
            class="warm-action shrink-0 ${AppState.pickerOpen || AppState.pickerQuery ? '' : 'hidden'}"
          >Close</button>
        </div>

        <div id="exercisePickerResultsContainer">
          ${renderExercisePickerResults()}
        </div>
      </div>
    </div>
  `;
}

function renderExercisePickerResults() {
  if (!AppState.pickerOpen && !AppState.pickerQuery.trim()) return '';
  const q = AppState.pickerQuery.trim();
  const assignedIds = new Set((AppState.workout?.exercises || []).map((e) => e.id));
  const results = AppState.pickerResults || [];
  const exactMatch = results.some((r) => r.name.toLowerCase() === q.toLowerCase());

  return `
    <div class="soft-panel space-y-3">
      ${
        q && !exactMatch
          ? `
        <div class="space-y-2 pb-2">
          <div class="flex items-center justify-between gap-2">
            <span class="ink-serif italic t-md text-[#191715]">Create custom “${esc(q)}”</span>
            <button type="button" onclick="createCustomExercise()" class="warm-action is-active">+ Custom</button>
          </div>
          ${
            results.some((r) => r.video_filename)
              ? `
            <select onchange="AppState.customVideoFilename = this.value" class="ink-input w-full t-sm">
              <option value="">No reference film (standalone custom)</option>
              ${results
                .filter((r) => r.video_filename)
                .slice(0, 6)
                .map(
                  (r) =>
                    `<option value="${esc(r.video_filename)}" ${AppState.customVideoFilename === r.video_filename ? 'selected' : ''}>Link film: ${esc(r.name)}</option>`
                )
                .join('')}
            </select>
          `
              : ''
          }
        </div>
      `
          : ''
      }

      ${
        results.length === 0
          ? `<div class="t-sm text-[#4a443d] py-1">No matching MoveKit films. Use “+ Custom” above.</div>`
          : `
        <div class="max-h-52 overflow-y-auto space-y-2.5">
          ${results
            .slice(0, 20)
            .map((r) => {
              const already = assignedIds.has(r.id);
              return `
              <div class="flex items-center justify-between gap-2 py-0.5">
                <div class="min-w-0">
                  <div class="ink-serif t-md text-[#191715] truncate">
                    ${esc(r.name)}
                  </div>
                  <div class="t-sm uppercase tracking-[0.08em] text-[#4a443d]">
                    ${esc(r.muscle_hint)}${r.video_filename ? ' · ▶ Film' : ' · Custom'}
                  </div>
                </div>
                <button
                  type="button"
                  onclick="addExerciseToDay('${esc(r.id)}')"
                  class="warm-action shrink-0 ${already ? 'is-active' : ''}"
                  ${already ? 'disabled' : ''}
                >${already ? 'Added' : '+ Add'}</button>
              </div>
            `;
            })
            .join('')}
        </div>
      `
      }
    </div>
  `;
}

/* --------------------------------------------------------------------------
 * RECIPES VIEW (Swipeable Saved <-> Discover Tabs + Dual Dropdowns)
 * -------------------------------------------------------------------------- */

function recipeMatchesFilters(rec) {
  const meal = AppState.mealFilter;
  if (meal && meal !== 'All') {
    const recMeal = String(rec.meal_type || '').toLowerCase();
    const title = String(rec.title || '').toLowerCase();
    if (recMeal !== meal.toLowerCase() && !title.includes(meal.toLowerCase())) {
      return false;
    }
  }

  for (const df of AppState.dietaryFilters) {
    const tags = (rec.dietary_tags || []).map((t) => t.toLowerCase());
    const allergens = (rec.allergens || []).map((a) => a.toLowerCase());
    const ingText = (rec.ingredients || []).join(' ').toLowerCase();
    const titleText = String(rec.title || '').toLowerCase();

    if (df === 'High-Protein') {
      if (!tags.includes('high-protein') && Number(rec.protein_g) < 28) return false;
    } else if (df === 'Gluten-Free') {
      if (!tags.includes('gluten-free') && allergens.some((a) => a.includes('wheat') || a.includes('gluten'))) return false;
    } else if (df === 'Dairy-Free') {
      if (!tags.includes('dairy-free') && allergens.some((a) => a.includes('dairy') || a.includes('milk'))) return false;
    } else if (df === 'Nut-Free') {
      if (!tags.includes('nut-free') && allergens.some((a) => a.includes('nut') || a.includes('peanut'))) return false;
    } else if (df === 'Egg-Free') {
      if (!tags.includes('egg-free') && allergens.some((a) => a.includes('egg'))) return false;
    } else if (df === 'Soy-Free') {
      if (!tags.includes('soy-free') && allergens.some((a) => a.includes('soy'))) return false;
    } else if (df === 'Vegetarian') {
      const hasMeat = /(chicken|beef|steak|pork|turkey|salmon|shrimp|fish|bacon|sausage|lamb|tuna)/.test(`${titleText} ${ingText}`);
      if (!tags.includes('vegetarian') && (hasMeat || allergens.some((a) => a.includes('fish') || a.includes('shellfish')))) {
        return false;
      }
    }
  }
  return true;
}

function renderRecipeThumb(rec, large = false) {
  const cls = large ? 'recipe-pfp-large' : 'recipe-pfp';
  if (rec.image_url) {
    return `<img src="${esc(rec.image_url)}" alt="${esc(rec.title)}" class="${cls}" loading="lazy" />`;
  }
  return `
    <div class="${cls} flex items-center justify-center">
      <svg width="24" height="24" viewBox="0 0 26 26" fill="none">
        <circle cx="13" cy="6.2" r="1.3" stroke="#191715" stroke-width="1.3"/>
        <path d="M5.2 17.5 C5.2 12.4 8.7 8.4 13 8.4 C17.3 8.4 20.8 12.4 20.8 17.5" stroke="#191715" stroke-width="1.3" stroke-linecap="round"/>
        <path d="M3.5 17.8 H22.5" stroke="#191715" stroke-width="1.3" stroke-linecap="round"/>
      </svg>
    </div>
  `;
}

function renderRecipeCardList(list, emptyLabel) {
  if (list.length === 0) {
    return `
      <div class="py-10 text-center space-y-2">
        <p class="ink-serif italic t-lg text-[#191715]">No recipes in ${esc(emptyLabel)}</p>
        <p class="t-sm uppercase tracking-[0.08em] text-[#4a443d]">Adjust meal/dietary filters or crawl below</p>
      </div>
    `;
  }

  return `
    <div class="space-y-6 pt-1">
      ${list
        .map((rec) => {
          const isOpen = AppState.expandedRecipeId === rec.id;
          const allergenText =
            rec.allergens && rec.allergens.length > 0
              ? `Allergens: ${rec.allergens.join(', ')}`
              : 'Allergens: None listed';
          return `
          <article>
            <div class="flex items-start gap-3.5 cursor-pointer" onclick="toggleRecipeAccordion('${esc(rec.id)}')">
              ${renderRecipeThumb(rec, false)}
              <div class="flex-1 min-w-0">
                <div class="flex items-center justify-between gap-2">
                  <span class="t-sm tracking-[0.06em] uppercase text-[#4a443d] truncate">
                    ${esc(rec.meal_type || 'Dinner')} · ${esc(rec.prep_time)}
                  </span>
                  <button
                    type="button"
                    onclick="event.stopPropagation(); toggleRecipeSave('${esc(rec.id)}')"
                    class="warm-action shrink-0 ${rec.is_saved ? 'is-active' : ''}"
                  >${rec.is_saved ? '✓ Saved' : '+ Save'}</button>
                </div>

                <h3 class="ink-serif t-lg font-semibold text-[#191715] mt-1">
                  ${esc(rec.title)}
                </h3>

                <div class="t-sm uppercase tracking-[0.06em] text-[#4a443d] mt-1">
                  ${rec.kcal} kcal · ${rec.protein_g}g P · ${rec.carbs_g}g C · ${rec.fat_g}g F
                </div>

                <div class="flex items-center justify-between gap-2 mt-1">
                  <span class="ink-serif italic t-sm text-[#4a443d] truncate">${esc(allergenText)}</span>
                  <a
                    href="${esc(rec.source_url)}"
                    target="_blank"
                    rel="noopener noreferrer"
                    onclick="event.stopPropagation()"
                    class="t-sm text-[#191715] underline decoration-[#191715]/40 shrink-0"
                  >↗ ${esc(rec.source_domain)}</a>
                </div>
              </div>
            </div>

            ${
              isOpen
                ? `
              <div class="mt-4 soft-panel space-y-4">
                <div class="flex items-center gap-3.5">
                  ${renderRecipeThumb(rec, true)}
                  <div class="space-y-2">
                    <div class="t-sm uppercase tracking-[0.08em] text-[#4a443d]">
                      ${rec.image_source === 'custom_photo' ? 'Cooked Photo' : rec.image_source === 'source_og' ? 'Source Photo' : 'Ink Plate'}
                    </div>
                    <button
                      type="button"
                      onclick="triggerCookedPhotoUpload('${esc(rec.id)}')"
                      class="warm-action"
                    >📷 Cooked Photo</button>
                    <div>
                      <a
                        href="${esc(rec.source_url)}"
                        target="_blank"
                        rel="noopener noreferrer"
                        class="t-sm uppercase tracking-[0.08em] underline text-[#191715]"
                      >Open Source Recipe ↗</a>
                    </div>
                  </div>
                </div>

                <div>
                  <div class="tracked-caps t-sm text-[#4a443d] mb-1.5">Ingredients (${rec.servings} servings)</div>
                  <ul class="space-y-1.5">
                    ${(rec.ingredients || [])
                      .map(
                        (ing) => `
                      <li class="flex items-start gap-2 ink-serif t-md text-[#191715]">
                        <span class="t-sm mt-1">✦</span>
                        <span>${esc(ing)}</span>
                      </li>
                    `
                      )
                      .join('')}
                  </ul>
                </div>

                <div>
                  <div class="tracked-caps t-sm text-[#4a443d] mb-1.5">Preparation</div>
                  <ol class="space-y-2">
                    ${(rec.steps || [])
                      .map(
                        (st, idx) => `
                      <li class="flex items-start gap-2.5 ink-serif t-md text-[#191715]">
                        <span class="font-sans t-sm font-semibold text-[#4a443d] mt-1">0${idx + 1}.</span>
                        <span>${esc(st)}</span>
                      </li>
                    `
                      )
                      .join('')}
                  </ol>
                </div>
              </div>
            `
                : ''
            }
          </article>
        `;
        })
        .join('')}
    </div>
  `;
}

function renderRecipesView() {
  const savedAll = AppState.recipes.saved || [];
  const discoverAll = AppState.recipes.discover || [];
  const savedFiltered = savedAll.filter(recipeMatchesFilters);
  const discoverFiltered = discoverAll.filter(recipeMatchesFilters);
  const isDiscover = AppState.recipeTab === 'discover';
  const dietaryCount = AppState.dietaryFilters.length;

  return `
    <div class="space-y-4 pt-2">
      <!-- Swipeable Tab Header (Saved <-> Discover) -->
      <div class="ink-write-line recipe-tabs-header">
        <button
          id="recipeTabBtnSaved"
          type="button"
          onclick="setRecipeTab('saved')"
          class="recipe-tab-btn ${!isDiscover ? 'is-active' : ''}"
        >Saved (${savedFiltered.length})</button>
        <button
          id="recipeTabBtnDiscover"
          type="button"
          onclick="setRecipeTab('discover')"
          class="recipe-tab-btn ${isDiscover ? 'is-active' : ''}"
        >Discover (${discoverFiltered.length})</button>
      </div>

      <!-- Two Clean Dropdown Filters (Meal + Dietary Restrictions) -->
      <div class="flex items-center gap-3 relative z-30">
        <!-- Meal Category Dropdown -->
        <div class="dropdown-wrap flex-1" onclick="event.stopPropagation()">
          <button
            type="button"
            onclick="toggleDropdown('meal')"
            class="warm-action dropdown-trigger ${AppState.mealFilter !== 'All' ? 'is-active' : ''}"
          >
            <span>${AppState.mealFilter === 'All' ? 'Meal: All' : esc(AppState.mealFilter)}</span>
            <span>▾</span>
          </button>
          ${
            AppState.openDropdown === 'meal'
              ? `
            <div class="dropdown-menu">
              ${MEAL_OPTIONS.map(
                (m) => `
                <button
                  type="button"
                  onclick="selectMealFilter('${m}')"
                  class="dropdown-item ${AppState.mealFilter === m ? 'is-selected' : ''}"
                >
                  <span>${m === 'All' ? 'All Meals' : esc(m)}</span>
                  ${AppState.mealFilter === m ? '<span>✓</span>' : ''}
                </button>
              `
              ).join('')}
            </div>
          `
              : ''
          }
        </div>

        <!-- Secondary Dietary Restrictions Dropdown -->
        <div class="dropdown-wrap flex-1" onclick="event.stopPropagation()">
          <button
            type="button"
            onclick="toggleDropdown('dietary')"
            class="warm-action dropdown-trigger ${dietaryCount > 0 ? 'is-active' : ''}"
          >
            <span>${dietaryCount > 0 ? `Dietary (${dietaryCount})` : 'Dietary'}</span>
            <span>▾</span>
          </button>
          ${
            AppState.openDropdown === 'dietary'
              ? `
            <div class="dropdown-menu dropdown-menu-right">
              ${DIETARY_OPTIONS.map((opt) => {
                const checked = AppState.dietaryFilters.includes(opt);
                return `
                  <button
                    type="button"
                    onclick="toggleDietaryOption('${opt}')"
                    class="dropdown-item ${checked ? 'is-selected' : ''}"
                  >
                    <span>${esc(opt)}</span>
                    <span>${checked ? '✓' : ''}</span>
                  </button>
                `;
              }).join('')}
              ${
                dietaryCount > 0
                  ? `
                <button type="button" onclick="clearDietaryOptions()" class="dropdown-item text-[#4a443d]">
                  <span>Clear filters</span>
                  <span>×</span>
                </button>
              `
                  : ''
              }
            </div>
          `
              : ''
          }
        </div>
      </div>

      <!-- Swipeable Horizontal Track (Saved Left | Discover Right) -->
      <div
        id="recipeSwipeViewport"
        class="recipe-swipe-viewport ink-write-line"
        ontouchstart="onRecipeSwipeStart(event)"
        ontouchend="onRecipeSwipeEnd(event)"
        onpointerdown="onRecipePointerDown(event)"
        onpointerup="onRecipePointerUp(event)"
      >
        <div
          id="recipeSwipeTrack"
          class="recipe-swipe-track"
          style="transform: translateX(${isDiscover ? '-50%' : '0%'});"
        >
          <!-- Panel 0: Saved -->
          <div id="recipePanelSaved" class="recipe-swipe-panel ${!isDiscover ? 'is-active' : ''}">
            ${renderRecipeCardList(savedFiltered, 'Saved')}
          </div>

          <!-- Panel 1: Discover -->
          <div id="recipePanelDiscover" class="recipe-swipe-panel ${isDiscover ? 'is-active' : ''} space-y-5">
            <form onsubmit="handleDiscoverRecipes(event)" class="soft-panel space-y-3">
              <div class="flex items-center justify-between t-sm uppercase tracking-[0.1em] text-[#4a443d]">
                <span>Hydrogen Recipe Search</span>
                <span>5 Verified Links</span>
              </div>
              <div class="flex items-center gap-2">
                <input
                  id="discoverQueryInput"
                  type="text"
                  class="ink-input flex-1"
                  value="${esc(AppState.discoverQuery)}"
                  oninput="AppState.discoverQuery = this.value"
                  placeholder="Describe any craving or ingredients..."
                  ${AppState.isDiscovering ? 'disabled' : ''}
                />
                <button type="submit" class="warm-action is-active shrink-0" ${AppState.isDiscovering ? 'disabled' : ''}>
                  ${AppState.isDiscovering ? 'Crawling…' : 'Crawl'}
                </button>
              </div>
              ${
                AppState.isDiscovering
                  ? `<div class="ink-serif italic t-md text-[#4a443d]">Searching live recipe sites with Gemini 4 Hydrogen…</div>`
                  : ''
              }
              ${
                AppState.discoverError
                  ? `
                <div class="t-sm text-[#191715] space-y-2 pt-1">
                  <div>${esc(AppState.discoverError)}</div>
                  ${
                    AppState.discoverError.toLowerCase().includes('key')
                      ? `<button type="button" onclick="selectView('vault')" class="warm-action is-active">Open Vault →</button>`
                      : ''
                  }
                </div>
              `
                  : ''
              }
            </form>

            ${renderRecipeCardList(discoverFiltered, 'Discover')}
          </div>
        </div>
      </div>
    </div>
  `;
}

/* --------------------------------------------------------------------------
 * VAULT VIEW (Storage Meter, Clutter Sweep & Hydrogen API Key)
 * -------------------------------------------------------------------------- */

function renderVaultView() {
  const st = AppState.storage;
  if (!st) {
    return `<div class="pt-6 ink-serif italic t-md text-[#4a443d]">Measuring ledger storage…</div>`;
  }

  const maxCapBytes = (st.settings.cache_max_mb || 25) * 1024 * 1024;
  const bars = [
    {
      label: 'SQLite Ledger',
      val: formatBytes(st.db_bytes),
      pct: Math.max(4, Math.min(100, Math.round((st.db_bytes / (2 * 1024 * 1024)) * 100))),
    },
    {
      label: `Saved Photos (${st.saved_media_files})`,
      val: formatBytes(st.saved_media_bytes),
      pct: Math.max(4, Math.min(100, Math.round((st.saved_media_bytes / (10 * 1024 * 1024)) * 100))),
    },
    {
      label: `Discover Cache (${st.counts.cached_recipes})`,
      val: formatBytes(st.cache_media_bytes),
      pct: Math.max(2, Math.min(100, Math.round((st.cache_media_bytes / maxCapBytes) * 100))),
    },
  ];

  return `
    <div class="space-y-6 pt-2">
      <div class="ink-write-line flex items-start justify-between gap-2">
        <div>
          <div class="tracked-caps t-sm text-[#191715]">Vault &amp; Clutter</div>
          <p class="ink-serif italic t-lg text-[#4a443d] mt-1">
            ${formatBytes(st.app_data_bytes)} ledger data on disk
          </p>
        </div>
        <button type="button" onclick="sweepClutter()" class="warm-action is-active shrink-0">
          Sweep Clutter
        </button>
      </div>

      <!-- Ink-Drawn Storage Meter Bars -->
      <div class="space-y-3.5">
        ${bars
          .map((b) => {
            const lineLen = Math.round((b.pct / 100) * 280);
            return `
            <div class="ink-write-line">
              <div class="flex items-baseline justify-between t-sm mb-1">
                <span class="uppercase tracking-[0.1em] text-[#191715]">${esc(b.label)}</span>
                <span class="tabular-nums font-medium text-[#191715]">${esc(b.val)}</span>
              </div>
              <svg viewBox="0 0 280 8" class="w-full h-[8px] overflow-visible">
                <line x1="0" y1="4" x2="280" y2="4" stroke="#191715" stroke-opacity="0.18" stroke-width="1" />
                <line x1="0" y1="4" x2="${lineLen}" y2="4" stroke="#191715" stroke-width="2.2" stroke-linecap="round" class="ink-stroke-draw" />
                <circle cx="${lineLen}" cy="4" r="2.3" fill="#191715" />
              </svg>
            </div>
          `;
          })
          .join('')}

        <div class="ink-write-line soft-panel t-sm text-[#4a443d] space-y-1">
          <div class="flex justify-between text-[#191715]">
            <span class="uppercase tracking-[0.1em]">MoveKit Reference</span>
            <span class="font-medium">${st.movekit_count} MP4s</span>
          </div>
          <div>Mac source: ${formatBytes(st.movekit_bytes)} · iOS HEVC est: ~350 MB</div>
        </div>
      </div>

      <!-- Preferences & Auto-Janitor Policy (Negative space, no borders) -->
      <div class="ink-write-line space-y-3">
        <div class="flex items-center justify-between">
          <span class="tracked-caps t-sm text-[#4a443d]">Weight Unit</span>
          <div class="flex gap-2">
            <button type="button" onclick="saveWeightUnit('lbs')" class="warm-action ${st.settings.weight_unit === 'lbs' ? 'is-active' : ''}">LBS</button>
            <button type="button" onclick="saveWeightUnit('kg')" class="warm-action ${st.settings.weight_unit === 'kg' ? 'is-active' : ''}">KG</button>
          </div>
        </div>

        <div class="flex items-center justify-between">
          <span class="tracked-caps t-sm text-[#4a443d]">Auto-Expire</span>
          <div class="flex gap-2">
            ${[3, 7, 14]
              .map(
                (d) => `
              <button type="button" onclick="saveJanitorTtl(${d})" class="warm-action ${st.settings.cache_ttl_days === d ? 'is-active' : ''}">${d}d</button>
            `
              )
              .join('')}
          </div>
        </div>
      </div>

      <!-- Gemini 4 Hydrogen API Key -->
      <form onsubmit="saveGeminiApiKey(event)" class="ink-write-line space-y-2.5">
        <div class="flex items-center justify-between t-sm">
          <span class="tracked-caps text-[#4a443d]">Hydrogen Key</span>
          <span class="uppercase tracking-[0.08em] ${st.settings.has_api_key ? 'text-[#191715] font-semibold' : 'text-[#4a443d]'}">
            ${st.settings.has_api_key ? `Connected (${esc(st.settings.masked_api_key)})` : 'Not Set'}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <input
            id="apiKeyInput"
            type="password"
            class="ink-input flex-1"
            placeholder="${st.settings.has_api_key ? 'Paste new key to replace...' : 'AIza...'}"
          />
          <button type="submit" class="warm-action is-active shrink-0">Save Key</button>
        </div>
        <p class="ink-serif italic t-md text-[#4a443d]">
          Stored locally in SQLite. Your sideloaded Swift app calls Gemini directly over HTTPS without requiring your Mac.
        </p>
      </form>
    </div>
  `;
}

/* --------------------------------------------------------------------------
 * RENDER CONTROLLER & INTERACTIVE HANDLERS
 * -------------------------------------------------------------------------- */

function renderCurrentView(animate = true) {
  updateActiveNavIndicator();
  let html = '';
  if (AppState.activeView === 'recipes') {
    html = renderRecipesView();
  } else if (AppState.activeView === 'vault') {
    html = renderVaultView();
  } else {
    html = renderWorkoutsView();
  }
  viewport.innerHTML = html;
  if (animate) {
    viewport.scrollTop = 0;
    triggerInkWriteAnimation();
  } else {
    viewport.querySelectorAll('.ink-write-line, .ink-stroke-draw').forEach((el) => {
      el.classList.add('ink-instant');
    });
  }
}

function selectView(viewName) {
  AppState.openDropdown = null;
  AppState.activeView = viewName;
  setNavFolded(true);
  renderCurrentView(true);
}

async function selectWorkoutDay(dow) {
  AppState.selectedDow = dow;
  AppState.selectedDate = isoDateForDowInCurrentWeek(dow);
  try {
    const data = await apiFetch(`/api/workouts?day=${dow}&date=${AppState.selectedDate}`);
    AppState.workout = data;
    if (dow === AppState.todayDow) {
      AppState.todayCompletionPct = data.completion_pct;
      updateTopProgressBar(data.completion_pct);
    }
    renderCurrentView(true);
  } catch (err) {
    showToast(err.message);
  }
}

function toggleEditRoutine() {
  AppState.editRoutineMode = !AppState.editRoutineMode;
  renderCurrentView(false);
}

async function saveRoutineTitle(e) {
  e.preventDefault();
  const input = document.getElementById('routineTitleInput');
  const title = input ? input.value.trim() : '';
  if (!title) return;
  try {
    const res = await apiFetch(`/api/routines/${AppState.selectedDow}`, {
      method: 'PUT',
      body: JSON.stringify({ title, session_date: AppState.selectedDate }),
    });
    AppState.workout = res.workout;
    AppState.daySummaries = res.day_summaries;
    AppState.editRoutineMode = false;
    renderCurrentView(false);
    showToast('Routine title saved');
  } catch (err) {
    showToast(err.message);
  }
}

function toggleExerciseVideo(exId) {
  AppState.openVideos[exId] = !AppState.openVideos[exId];
  renderCurrentView(false);
}

function toggleTrend(exId) {
  AppState.openTrends[exId] = !AppState.openTrends[exId];
  renderCurrentView(false);
}

function applyWorkoutUpdate(res) {
  if (res.workout) {
    AppState.workout = res.workout;
    if (res.workout.day_of_week === AppState.todayDow) {
      AppState.todayCompletionPct = res.workout.completion_pct;
      updateTopProgressBar(res.workout.completion_pct);
    }
  }
  if (res.day_summaries) AppState.daySummaries = res.day_summaries;
  if (res.storage) AppState.storage = res.storage;
}

async function addWorkingSet(exId) {
  const ex = AppState.workout?.exercises?.find((e) => e.id === exId);
  const lastSet = ex && ex.sets.length > 0 ? ex.sets[ex.sets.length - 1] : null;
  const reps = lastSet ? lastSet.reps : ex?.suggested_reps || 8;
  const weight = lastSet ? lastSet.weight : ex?.suggested_weight || 0;
  try {
    const res = await apiFetch('/api/workouts/sets', {
      method: 'POST',
      body: JSON.stringify({
        exercise_id: exId,
        session_date: AppState.selectedDate,
        day_of_week: AppState.selectedDow,
        reps,
        weight,
        completed: true,
      }),
    });
    applyWorkoutUpdate(res);
    renderCurrentView(false);
    showToast('Working set logged');
  } catch (err) {
    showToast(err.message);
  }
}

async function updateSetField(setId, exId, newReps, newWeight, completed) {
  const ex = AppState.workout?.exercises?.find((e) => e.id === exId);
  const setObj = ex?.sets?.find((s) => s.id === setId);
  if (!setObj) return;
  const reps = newReps !== null ? Math.max(0, parseInt(newReps, 10) || 0) : setObj.reps;
  const weight = newWeight !== null ? Math.max(0, parseFloat(newWeight) || 0) : setObj.weight;
  try {
    const res = await apiFetch('/api/workouts/sets', {
      method: 'POST',
      body: JSON.stringify({
        id: setId,
        exercise_id: exId,
        session_date: AppState.selectedDate,
        day_of_week: AppState.selectedDow,
        reps,
        weight,
        completed,
      }),
    });
    applyWorkoutUpdate(res);
    renderCurrentView(false);
  } catch (err) {
    showToast(err.message);
  }
}

async function toggleSetComplete(setId, exId, reps, weight, newCompleted) {
  try {
    const res = await apiFetch('/api/workouts/sets', {
      method: 'POST',
      body: JSON.stringify({
        id: setId,
        exercise_id: exId,
        session_date: AppState.selectedDate,
        day_of_week: AppState.selectedDow,
        reps,
        weight,
        completed: newCompleted,
      }),
    });
    applyWorkoutUpdate(res);
    renderCurrentView(false);
  } catch (err) {
    showToast(err.message);
  }
}

async function deleteWorkoutSet(setId) {
  try {
    const res = await apiFetch(`/api/workouts/sets/${setId}?day=${AppState.selectedDow}`, {
      method: 'DELETE',
    });
    applyWorkoutUpdate(res);
    renderCurrentView(false);
  } catch (err) {
    showToast(err.message);
  }
}

function updateExercisePickerDom() {
  const container = document.getElementById('exercisePickerResultsContainer');
  if (container) {
    container.innerHTML = renderExercisePickerResults();
  }
  const closeBtn = document.getElementById('exercisePickerCloseBtn');
  if (closeBtn) {
    closeBtn.classList.toggle('hidden', !(AppState.pickerOpen || AppState.pickerQuery));
  }
}

async function openExercisePicker() {
  AppState.pickerOpen = true;
  if (AppState.pickerResults.length === 0) {
    await fetchPickerExercises(AppState.pickerQuery);
  } else {
    updateExercisePickerDom();
  }
}

function closeExercisePicker() {
  AppState.pickerOpen = false;
  AppState.pickerQuery = '';
  AppState.customVideoFilename = '';
  const inp = document.getElementById('exercisePickerInput');
  if (inp) inp.value = '';
  updateExercisePickerDom();
}

function handleExerciseSearch(val) {
  AppState.pickerQuery = val;
  AppState.pickerOpen = true;
  updateExercisePickerDom();
  clearTimeout(pickerSearchTimer);
  pickerSearchTimer = setTimeout(() => fetchPickerExercises(val), 140);
}

async function fetchPickerExercises(query) {
  try {
    const data = await apiFetch(`/api/exercises?q=${encodeURIComponent(query)}&limit=25`);
    AppState.pickerResults = data.exercises || [];
    updateExercisePickerDom();
  } catch (_) {}
}

async function addExerciseToDay(exId) {
  try {
    const res = await apiFetch(`/api/routines/${AppState.selectedDow}/exercises`, {
      method: 'POST',
      body: JSON.stringify({ exercise_id: exId, session_date: AppState.selectedDate }),
    });
    applyWorkoutUpdate(res);
    renderCurrentView(false);
    showToast('Added to routine');
  } catch (err) {
    showToast(err.message);
  }
}

async function removeExerciseFromDay(exId) {
  try {
    const res = await apiFetch(`/api/routines/${AppState.selectedDow}/exercises/${encodeURIComponent(exId)}?date=${AppState.selectedDate}`, {
      method: 'DELETE',
    });
    applyWorkoutUpdate(res);
    renderCurrentView(false);
    showToast('Removed from day');
  } catch (err) {
    showToast(err.message);
  }
}

async function createCustomExercise() {
  const name = AppState.pickerQuery.trim();
  if (!name) return;
  try {
    const res = await apiFetch('/api/exercises/custom', {
      method: 'POST',
      body: JSON.stringify({
        name,
        video_filename: AppState.customVideoFilename || null,
        day_of_week: AppState.selectedDow,
        session_date: AppState.selectedDate,
      }),
    });
    applyWorkoutUpdate(res);
    AppState.pickerQuery = '';
    AppState.pickerOpen = false;
    AppState.customVideoFilename = '';
    renderCurrentView(false);
    showToast(`Added custom: ${name}`);
  } catch (err) {
    showToast(err.message);
  }
}

/* Recipe Tabs, Swipe & Dropdown Handlers */

function setRecipeTab(tab) {
  if (tab !== 'saved' && tab !== 'discover') return;
  AppState.openDropdown = null;
  AppState.expandedRecipeId = null;
  if (AppState.recipeTab === tab) return;
  AppState.recipeTab = tab;

  const track = document.getElementById('recipeSwipeTrack');
  const btnSaved = document.getElementById('recipeTabBtnSaved');
  const btnDiscover = document.getElementById('recipeTabBtnDiscover');
  const panelSaved = document.getElementById('recipePanelSaved');
  const panelDiscover = document.getElementById('recipePanelDiscover');

  if (track && btnSaved && btnDiscover && panelSaved && panelDiscover) {
    const isDiscover = tab === 'discover';
    track.style.transform = `translateX(${isDiscover ? '-50%' : '0%'})`;
    btnSaved.classList.toggle('is-active', !isDiscover);
    btnDiscover.classList.toggle('is-active', isDiscover);
    panelSaved.classList.toggle('is-active', !isDiscover);
    panelDiscover.classList.toggle('is-active', isDiscover);
    viewport.scrollTop = 0;
  } else {
    renderCurrentView(false);
  }
}

let swipeTouchStart = null;
let swipePointerStart = null;

function onRecipeSwipeStart(e) {
  const t = e.touches?.[0];
  if (!t) return;
  swipeTouchStart = { x: t.clientX, y: t.clientY };
}

function onRecipeSwipeEnd(e) {
  if (!swipeTouchStart) return;
  const t = e.changedTouches?.[0];
  if (!t) return;
  const dx = t.clientX - swipeTouchStart.x;
  const dy = t.clientY - swipeTouchStart.y;
  swipeTouchStart = null;
  handleRecipeSwipeDelta(dx, dy);
}

function onRecipePointerDown(e) {
  if (e.pointerType === 'touch') return;
  swipePointerStart = { x: e.clientX, y: e.clientY };
}

function onRecipePointerUp(e) {
  if (e.pointerType === 'touch' || !swipePointerStart) return;
  const dx = e.clientX - swipePointerStart.x;
  const dy = e.clientY - swipePointerStart.y;
  swipePointerStart = null;
  handleRecipeSwipeDelta(dx, dy);
}

function handleRecipeSwipeDelta(dx, dy) {
  if (Math.abs(dx) < 48 || Math.abs(dx) < Math.abs(dy) * 1.25) return;
  if (dx < 0 && AppState.recipeTab === 'saved') {
    setRecipeTab('discover');
  } else if (dx > 0 && AppState.recipeTab === 'discover') {
    setRecipeTab('saved');
  }
}

function toggleDropdown(kind) {
  AppState.openDropdown = AppState.openDropdown === kind ? null : kind;
  renderCurrentView(false);
}

function selectMealFilter(meal) {
  AppState.mealFilter = meal;
  AppState.openDropdown = null;
  renderCurrentView(false);
}

function toggleDietaryOption(opt) {
  const idx = AppState.dietaryFilters.indexOf(opt);
  if (idx >= 0) {
    AppState.dietaryFilters.splice(idx, 1);
  } else {
    AppState.dietaryFilters.push(opt);
  }
  renderCurrentView(false);
}

function clearDietaryOptions() {
  AppState.dietaryFilters = [];
  AppState.openDropdown = null;
  renderCurrentView(false);
}

function toggleRecipeAccordion(id) {
  AppState.expandedRecipeId = AppState.expandedRecipeId === id ? null : id;
  renderCurrentView(false);
}

async function toggleRecipeSave(id) {
  try {
    const res = await apiFetch(`/api/recipes/${encodeURIComponent(id)}/toggle-save`, {
      method: 'POST',
      body: '{}',
    });
    if (res.recipes) AppState.recipes = res.recipes;
    if (res.storage) AppState.storage = res.storage;
    renderCurrentView(false);
    showToast(res.recipe?.is_saved ? 'Saved to ledger' : 'Moved to discover');
  } catch (err) {
    showToast(err.message);
  }
}

async function handleDiscoverRecipes(e) {
  e.preventDefault();
  const q = AppState.discoverQuery.trim();
  if (!q) {
    showToast('Enter a dish or ingredient');
    return;
  }
  AppState.isDiscovering = true;
  AppState.discoverError = '';
  renderCurrentView(false);

  try {
    const res = await apiFetch('/api/recipes/discover', {
      method: 'POST',
      body: JSON.stringify({
        query: q,
        meal_type: AppState.mealFilter === 'All' ? '' : AppState.mealFilter,
        dietary_filters: AppState.dietaryFilters,
      }),
    });
    AppState.recipes = res.recipes;
    AppState.storage = res.storage;
    AppState.isDiscovering = false;
    AppState.recipeTab = 'discover';
    renderCurrentView(true);
    showToast(`Found ${res.added_count} verified recipes`);
  } catch (err) {
    AppState.isDiscovering = false;
    AppState.discoverError = err.message;
    renderCurrentView(false);
  }
}

function triggerCookedPhotoUpload(recipeId) {
  AppState.pendingPhotoRecipeId = recipeId;
  photoInput.value = '';
  photoInput.click();
}

photoInput.addEventListener('change', async (e) => {
  const file = e.target.files?.[0];
  const recipeId = AppState.pendingPhotoRecipeId;
  if (!file || !recipeId) return;

  try {
    const dataUrl = await resizeImageFileToSquareJpeg(file, 480);
    const res = await apiFetch(`/api/recipes/${encodeURIComponent(recipeId)}/photo`, {
      method: 'POST',
      body: JSON.stringify({ image_base64: dataUrl }),
    });
    AppState.recipes = res.recipes;
    AppState.storage = res.storage;
    renderCurrentView(false);
    showToast('Cooked dish photo saved');
  } catch (err) {
    showToast(err.message || 'Could not process image');
  }
});

function resizeImageFileToSquareJpeg(file, targetSize) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        const canvas = document.createElement('canvas');
        canvas.width = targetSize;
        canvas.height = targetSize;
        const ctx = canvas.getContext('2d');
        const minSide = Math.min(img.width, img.height);
        const sx = (img.width - minSide) / 2;
        const sy = (img.height - minSide) / 2;
        ctx.drawImage(img, sx, sy, minSide, minSide, 0, 0, targetSize, targetSize);
        resolve(canvas.toDataURL('image/jpeg', 0.82));
      };
      img.onerror = () => reject(new Error('Invalid image file'));
      img.src = reader.result;
    };
    reader.onerror = () => reject(new Error('Could not read file'));
    reader.readAsDataURL(file);
  });
}

/* Vault & Settings handlers */

async function sweepClutter() {
  try {
    const res = await apiFetch('/api/storage/sweep', { method: 'POST', body: '{}' });
    AppState.recipes = res.recipes;
    AppState.storage = res.storage;
    renderCurrentView(true);
    const swept = res.sweep?.deleted_recipes || 0;
    const freed = formatBytes(res.sweep?.reclaimed_bytes || 0);
    showToast(`Swept ${swept} unsaved · Freed ${freed}`);
  } catch (err) {
    showToast(err.message);
  }
}

async function saveWeightUnit(unit) {
  try {
    const res = await apiFetch('/api/settings', {
      method: 'POST',
      body: JSON.stringify({ weight_unit: unit }),
    });
    AppState.storage = res.storage;
    renderCurrentView(false);
    showToast(`Unit set to ${unit.toUpperCase()}`);
  } catch (err) {
    showToast(err.message);
  }
}

async function saveJanitorTtl(days) {
  try {
    const res = await apiFetch('/api/settings', {
      method: 'POST',
      body: JSON.stringify({ cache_ttl_days: days }),
    });
    AppState.storage = res.storage;
    renderCurrentView(false);
    showToast(`Auto-clean set to ${days} days`);
  } catch (err) {
    showToast(err.message);
  }
}

async function saveGeminiApiKey(e) {
  e.preventDefault();
  const inp = document.getElementById('apiKeyInput');
  const val = inp ? inp.value.trim() : '';
  if (!val) {
    showToast('Paste a valid API key');
    return;
  }
  try {
    const res = await apiFetch('/api/settings', {
      method: 'POST',
      body: JSON.stringify({ gemini_api_key: val }),
    });
    AppState.storage = res.storage;
    AppState.discoverError = '';
    renderCurrentView(false);
    showToast('Gemini 4 Hydrogen key saved');
  } catch (err) {
    showToast(err.message);
  }
}

/* Global Event Bindings, Right-Edge Navbar Swipe & Bootstrap */

navButtons.forEach((btn) => {
  btn.addEventListener('click', () => {
    selectView(btn.getAttribute('data-view'));
  });
});

navFoldHandle.addEventListener('click', () => setNavFolded(true));
foldedEdgeTab.addEventListener('click', () => setNavFolded(false));

// Right-edge swipe to unfold/fold the navigation bar
let navEdgeStart = null;
phoneScreen.addEventListener('touchstart', (e) => {
  const t = e.touches?.[0];
  if (!t) return;
  const rect = phoneScreen.getBoundingClientRect();
  navEdgeStart = { x: t.clientX, y: t.clientY, nearRight: t.clientX >= rect.right - 44 };
}, { passive: true });

phoneScreen.addEventListener('touchend', (e) => {
  if (!navEdgeStart) return;
  const t = e.changedTouches?.[0];
  if (!t) return;
  const dx = t.clientX - navEdgeStart.x;
  const dy = t.clientY - navEdgeStart.y;
  const nearRight = navEdgeStart.nearRight;
  navEdgeStart = null;
  if (Math.abs(dx) < 34 || Math.abs(dx) < Math.abs(dy) * 1.2) return;
  if (AppState.navFolded && nearRight && dx < -34) {
    setNavFolded(false);
  } else if (!AppState.navFolded && nearRight && dx > 34) {
    setNavFolded(true);
  }
}, { passive: true });

document.addEventListener('click', () => {
  if (AppState.openDropdown) {
    AppState.openDropdown = null;
    renderCurrentView(false);
  }
});

async function refreshBootstrap(animate = true) {
  const localToday = localIsoDate(new Date());
  const boot = await apiFetch(`/api/bootstrap?date=${encodeURIComponent(localToday)}`);
  AppState.todayDate = boot.today_date;
  AppState.todayDow = boot.today_dow;
  AppState.selectedDow = boot.today_dow;
  AppState.selectedDate = boot.today_date;
  AppState.daySummaries = boot.day_summaries || [];
  AppState.workout = boot.workout;
  AppState.todayCompletionPct = boot.workout?.completion_pct ?? 0;
  AppState.recipes = boot.recipes || { saved: [], discover: [] };
  AppState.storage = boot.storage;

  updateTopProgressBar(AppState.todayCompletionPct);
  renderCurrentView(animate);
}

btnRefreshLedger.addEventListener('click', async () => {
  btnRefreshLedger.classList.remove('spinning');
  void btnRefreshLedger.offsetWidth;
  btnRefreshLedger.classList.add('spinning');
  try {
    await refreshBootstrap(true);
    showToast('Ledger refreshed');
  } catch (err) {
    showToast(err.message);
  }
});

window.addEventListener('DOMContentLoaded', async () => {
  updateHeaderDateGreeting();
  try {
    await refreshBootstrap(true);
  } catch (err) {
    viewport.innerHTML = `<div class="pt-6 ink-serif italic t-md text-[#191715]">Failed to connect to local ledger server: ${esc(err.message)}</div>`;
  }

  setTimeout(() => {
    if (!AppState.navFolded) {
      rightNavLineup.classList.remove('show-hints');
    }
  }, 2600);
});
