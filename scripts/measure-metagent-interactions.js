ObjC.import("stdlib");
ObjC.import("Foundation");

function fail(message) {
  throw new Error(message);
}

function progress(message) {
  // `console.log` is emitted on osascript's stderr, keeping stdout valid JSON.
  console.log(`[metagent-perf] ${message}`);
}

function monotonicMilliseconds() {
  return Number($.NSProcessInfo.processInfo.systemUptime) * 1000;
}

function waitUntil(predicate, timeoutMilliseconds, description) {
  const started = monotonicMilliseconds();
  while (monotonicMilliseconds() - started <= timeoutMilliseconds) {
    try {
      if (predicate()) {
        return monotonicMilliseconds() - started;
      }
    } catch (_) {
      // SwiftUI may replace an AX element while a view changes. Retry until the
      // bounded timeout instead of treating that expected transition as ready.
    }
    delay(0.01);
  }
  fail(`Timed out after ${timeoutMilliseconds}ms waiting for ${description}.`);
}

function processFor(systemEvents, processName) {
  const process = systemEvents.processes.byName(processName);
  if (!process.exists()) {
    fail(`No running ${processName} process is exposed to Accessibility.`);
  }
  return process;
}

function mainWindow(process, timeoutMilliseconds) {
  waitUntil(
    () => process.windows.byName("Metagent").exists(),
    timeoutMilliseconds,
    "the Metagent main window"
  );
  return process.windows.byName("Metagent");
}

function elementRole(element) {
  try {
    return element.role();
  } catch (_) {
    return null;
  }
}

function elementIdentifier(element) {
  try {
    return element.attributes.byName("AXIdentifier").value();
  } catch (_) {
    return null;
  }
}

function findDescendantByIdentifier(root, identifier) {
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.shift();
    if (elementIdentifier(current) === identifier) {
      return current;
    }
    let children = [];
    try {
      children = current.uiElements();
    } catch (_) {
      continue;
    }
    for (const child of children) {
      pending.push(child);
    }
  }
  return null;
}

function findDescendantByIdentifierPrefix(root, prefix) {
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.shift();
    const identifier = elementIdentifier(current);
    if (identifier && identifier.indexOf(prefix) === 0) {
      return current;
    }
    let children = [];
    try {
      children = current.uiElements();
    } catch (_) {
      continue;
    }
    for (const child of children) {
      pending.push(child);
    }
  }
  return null;
}

function waitForIdentifier(root, identifier, timeoutMilliseconds) {
  let found = null;
  waitUntil(() => {
    found = findDescendantByIdentifier(root, identifier);
    return found !== null;
  }, timeoutMilliseconds, `Accessibility identifier ${identifier}`);
  return found;
}

function waitForIdentifierPrefix(root, prefix, timeoutMilliseconds) {
  let found = null;
  waitUntil(() => {
    found = findDescendantByIdentifierPrefix(root, prefix);
    return found !== null;
  }, timeoutMilliseconds, `Accessibility identifier prefix ${prefix}`);
  return found;
}

function navigationButtons(window) {
  const identifiers = {
    Overview: "metagent.navigation.overview",
    Skills: "metagent.navigation.skills",
    MCPs: "metagent.navigation.mcps",
    Plugins: "metagent.navigation.plugins",
    Projects: "metagent.navigation.projects",
  };
  const buttons = {};
  for (const [name, identifier] of Object.entries(identifiers)) {
    const button = findDescendantByIdentifier(window, identifier);
    if (!button) {
      fail(`Missing required Accessibility navigation control ${identifier}.`);
    }
    buttons[name] = button;
  }
  buttons.count = Object.keys(identifiers).length +
    (findDescendantByIdentifier(window, "metagent.navigation.history") ? 1 : 0);
  return buttons;
}

function isSelected(button) {
  try {
    return button.selected() === true;
  } catch (_) {
    return false;
  }
}

function press(element) {
  const action = element.actions.byName("AXPress");
  if (!action.exists()) {
    fail("The target Accessibility control does not expose AXPress.");
  }
  action.perform();
}

function selectTab(button, timeoutMilliseconds, label) {
  const started = monotonicMilliseconds();
  press(button);
  waitUntil(() => isSelected(button), timeoutMilliseconds, `${label} selected state`);
  return monotonicMilliseconds() - started;
}

function contentReadyPrefix(section) {
  return `metagent.${section.toLowerCase()}.content.ready.`;
}

function selectTabToContentReady(
  window,
  button,
  section,
  timeoutMilliseconds
) {
  const started = monotonicMilliseconds();
  press(button);
  const selectedStateMilliseconds = waitUntil(
    () => isSelected(button),
    timeoutMilliseconds,
    `${section} selected state`
  );
  waitForIdentifierPrefix(
    window,
    section === "Overview"
      ? "metagent.overview.content.ready"
      : contentReadyPrefix(section),
    timeoutMilliseconds
  );
  return {
    contentReadyMilliseconds: monotonicMilliseconds() - started,
    selectedStateMilliseconds,
  };
}

function elementValue(element) {
  try {
    return String(element.value());
  } catch (_) {
    return null;
  }
}

function elementAttributeValue(element, name) {
  try {
    return String(element.attributes.byName(name).value());
  } catch (_) {
    return null;
  }
}

function elementName(element) {
  try {
    return String(element.name());
  } catch (_) {
    return null;
  }
}

function findDescendantByRoleAndName(root, role, name, requiresPress) {
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.shift();
    if (elementRole(current) === role && elementName(current) === name) {
      if (!requiresPress || current.actions.byName("AXPress").exists()) {
        return current;
      }
    }
    let children = [];
    try {
      children = current.uiElements();
    } catch (_) {
      continue;
    }
    for (const child of children) {
      pending.push(child);
    }
  }
  return null;
}

function findSortableHeader(root, name, maximumVisited = 512) {
  const pending = [root];
  let visited = 0;
  while (pending.length > 0 && visited < maximumVisited) {
    const current = pending.shift();
    visited += 1;
    const role = elementRole(current);
    if (
      role === "AXButton" &&
      elementName(current) === name &&
      current.actions.byName("AXPress").exists()
    ) {
      return current;
    }
    // A SwiftUI table can expose hundreds of row descendants before its
    // header group. Header lookup must never enumerate cell contents.
    if (role === "AXRow") {
      continue;
    }
    let children = [];
    try {
      children = current.uiElements();
    } catch (_) {
      continue;
    }
    const early = [];
    const ordinary = [];
    const rows = [];
    // SwiftUI places the header group after the visible rows on current macOS.
    // Probe direct children from the end and inspect only a group's immediate
    // buttons before adding anything to the fallback traversal.
    for (let index = children.length - 1; index >= 0; index -= 1) {
      const child = children[index];
      const childRole = elementRole(child);
      if (
        childRole === "AXButton" &&
        elementName(child) === name &&
        child.actions.byName("AXPress").exists()
      ) {
        return child;
      }
      if (childRole === "AXGroup") {
        let groupChildren = [];
        try {
          groupChildren = child.uiElements();
        } catch (_) {
          groupChildren = [];
        }
        for (const groupChild of groupChildren) {
          if (
            elementRole(groupChild) === "AXButton" &&
            elementName(groupChild) === name &&
            groupChild.actions.byName("AXPress").exists()
          ) {
            return groupChild;
          }
        }
        early.push(child);
      } else if (
        childRole === "AXScrollArea" ||
        childRole === "AXOutline" ||
        childRole === "AXTable"
      ) {
        early.push(child);
      } else if (childRole === "AXRow") {
        rows.push(child);
      } else {
        ordinary.push(child);
      }
    }
    pending.unshift(...early, ...ordinary, ...rows);
  }
  return null;
}

function contentElement(window, section, timeoutMilliseconds) {
  return waitForIdentifierPrefix(
    window,
    contentReadyPrefix(section),
    timeoutMilliseconds
  );
}

function waitForContentIdentifierChange(
  window,
  section,
  previousIdentifier,
  timeoutMilliseconds
) {
  let changed = null;
  waitUntil(() => {
    changed = findDescendantByIdentifierPrefix(window, contentReadyPrefix(section));
    return changed !== null && elementIdentifier(changed) !== previousIdentifier;
  }, timeoutMilliseconds, `${section} AX content-ready token to change`);
  return changed;
}

function menuItem(process, name, timeoutMilliseconds) {
  let item = null;
  waitUntil(() => {
    item = findDescendantByRoleAndName(process, "AXMenuItem", name, true);
    return item !== null;
  }, timeoutMilliseconds, `menu item ${name}`);
  return item;
}

function chooseMenuOption(
  process,
  window,
  section,
  control,
  option,
  timeoutMilliseconds,
  measured
) {
  if (elementValue(control) === option) {
    return null;
  }
  press(control);
  const item = menuItem(process, option, timeoutMilliseconds);
  const previous = elementIdentifier(contentElement(window, section, timeoutMilliseconds));
  const started = monotonicMilliseconds();
  press(item);
  waitForContentIdentifierChange(window, section, previous, timeoutMilliseconds);
  const elapsed = monotonicMilliseconds() - started;
  waitUntil(
    () => elementValue(control) === option,
    timeoutMilliseconds,
    `${section} filter value ${option}`
  );
  return measured ? elapsed : null;
}

function measureSort(
  window,
  section,
  headerName,
  timeoutMilliseconds
) {
  const content = contentElement(window, section, timeoutMilliseconds);
  // macOS exposes table headers in different containers across OS builds. A
  // bounded, row-skipping search keeps the observable exact without walking
  // every accessible cell and perturbing the app for minutes.
  const header = findSortableHeader(content, headerName) ||
    findSortableHeader(window, headerName);
  if (!header) {
    fail(`${section} table header ${headerName} is not exposed with AXPress.`);
  }
  const previous = elementIdentifier(content);
  const previousDirection = elementAttributeValue(header, "AXSortDirection");
  if (!previousDirection) {
    fail(`${section} table header ${headerName} has no AXSortDirection.`);
  }
  const started = monotonicMilliseconds();
  press(header);
  waitUntil(() => {
    const currentContent = findDescendantByIdentifierPrefix(
      window,
      contentReadyPrefix(section)
    );
    const currentHeader = currentContent === null
      ? null
      : findSortableHeader(currentContent, headerName) ||
        findSortableHeader(window, headerName);
    return currentContent !== null &&
      currentHeader !== null &&
      elementIdentifier(currentContent) !== previous &&
      elementAttributeValue(currentHeader, "AXSortDirection") !== previousDirection;
  }, timeoutMilliseconds, `${section} sorted AX table content and direction to change`);
  return monotonicMilliseconds() - started;
}

function findReloadControl(window) {
  const topLevel = window.uiElements()[0];
  for (const element of topLevel.uiElements()) {
    try {
      if (
        elementRole(element) === "AXButton" &&
        element.help() ===
          "Rescan skills, Doctor findings, and MCP configuration, and continue indexing session history"
      ) {
        return element;
      }
    } catch (_) {
      // Ignore unrelated elements whose optional AXHelp cannot be read.
    }
  }
  return null;
}

function runTabs(window, iterations, timeoutMilliseconds) {
  const buttons = navigationButtons(window);
  if (!isSelected(buttons.Overview)) {
    selectTabToContentReady(
      window,
      buttons.Overview,
      "Overview",
      timeoutMilliseconds
    );
  }
  const samples = [];
  const destinations = ["Skills", "MCPs", "Plugins", "Projects"];
  for (let iteration = 1; iteration <= iterations; iteration += 1) {
    for (const destination of destinations) {
      progress(`tabs ${iteration}/${iterations}: Overview to ${destination}`);
      const forward = selectTabToContentReady(
        window,
        buttons[destination],
        destination,
        timeoutMilliseconds
      );
      const backward = selectTabToContentReady(
        window,
        buttons.Overview,
        "Overview",
        timeoutMilliseconds
      );
      progress(
        `tabs ${iteration}/${iterations}: ${destination} round trip ready ` +
        `(${Math.round(forward.contentReadyMilliseconds)}ms forward, ` +
        `${Math.round(backward.contentReadyMilliseconds)}ms back)`
      );
      for (const [interaction, measured] of [
        [`Overview to ${destination}`, forward],
        [`${destination} to Overview`, backward],
      ]) {
        samples.push(
          {
            metric: "tab_input_to_selected_state_ms",
            interaction,
            iteration,
            value_ms: measured.selectedStateMilliseconds,
            selected_state_observed: true,
            presentation_observed: false,
          },
          {
            metric: "tab_input_to_ax_content_ready_ms",
            interaction,
            iteration,
            value_ms: measured.contentReadyMilliseconds,
            ax_content_ready_observed: true,
            presentation_observed: true,
            presentation_fidelity: "accessibility_content_ready",
          }
        );
      }
    }
  }
  return {
    automation: "macos_accessibility",
    navigation_button_count: buttons.count,
    samples,
    coverage_gaps: [
      "AX content-ready proves SwiftUI exposed the destination state through Accessibility; it does not observe the first painted or composited pixel.",
    ],
  };
}

function normalizeSkillsSummary(window, timeoutMilliseconds) {
  const summary = waitForIdentifier(
    window,
    "metagent.skills.view.summary",
    timeoutMilliseconds
  );
  if (isSelected(summary)) {
    return;
  }
  const previous = elementIdentifier(contentElement(window, "Skills", timeoutMilliseconds));
  press(summary);
  waitUntil(
    () => isSelected(summary),
    timeoutMilliseconds,
    "Skills Summary view selected state"
  );
  waitForContentIdentifierChange(window, "Skills", previous, timeoutMilliseconds);
}

function runCommonInteractions(
  process,
  window,
  iterations,
  timeoutMilliseconds
) {
  const tabResult = runTabs(window, iterations, timeoutMilliseconds);
  const buttons = navigationButtons(window);
  const samples = tabResult.samples.slice();
  const skippedSections = [];

  const filters = [
    {
      tab: "Skills",
      section: "Skills",
      control: "metagent.skills.usage-filter",
      baseline: "All skills",
      alternate: "Observed",
    },
    {
      tab: "MCPs",
      section: "MCPs",
      control: "metagent.mcps.status-filter",
      baseline: "All",
      alternate: "Needs attention",
    },
    {
      tab: "Plugins",
      section: "Plugins",
      control: "metagent.plugins.show-filter",
      baseline: "All",
      alternate: "Manual updates",
    },
  ];
  for (const specification of filters) {
    selectTabToContentReady(
      window,
      buttons[specification.tab],
      specification.section,
      timeoutMilliseconds
    );
    if (specification.section === "Skills") {
      normalizeSkillsSummary(window, timeoutMilliseconds);
    }
    let control = waitForIdentifier(window, specification.control, timeoutMilliseconds);
    chooseMenuOption(
      process,
      window,
      specification.section,
      control,
      specification.baseline,
      timeoutMilliseconds,
      false
    );
    for (let iteration = 1; iteration <= iterations; iteration += 1) {
      for (const option of [specification.alternate, specification.baseline]) {
        progress(
          `filters ${specification.section} ${iteration}/${iterations}: ${option}`
        );
        control = waitForIdentifier(window, specification.control, timeoutMilliseconds);
        const elapsed = chooseMenuOption(
          process,
          window,
          specification.section,
          control,
          option,
          timeoutMilliseconds,
          true
        );
        if (elapsed === null) {
          fail(
            `${specification.section} filter did not leave ${option}; ` +
            "the scenario cannot produce a truthful state transition."
          );
        }
        samples.push({
          metric: "filter_input_to_ax_content_ready_ms",
          interaction: `${specification.section} filter to ${option}`,
          iteration,
          value_ms: elapsed,
          ax_content_ready_observed: true,
          presentation_observed: true,
          presentation_fidelity: "accessibility_content_ready",
        });
        progress(
          `filters ${specification.section} ${iteration}/${iterations}: ` +
          `${option} ready (${Math.round(elapsed)}ms)`
        );
      }
    }
  }

  const sorts = [
    { tab: "Skills", section: "Skills", header: "Skill" },
    { tab: "MCPs", section: "MCPs", header: "MCP" },
    { tab: "Plugins", section: "Plugins", header: "Plugin" },
    { tab: "Projects", section: "Projects", header: "Project" },
  ];
  let observedSortSamples = 0;
  for (const specification of sorts) {
    selectTabToContentReady(
      window,
      buttons[specification.tab],
      specification.section,
      timeoutMilliseconds
    );
    if (specification.section === "Skills") {
      normalizeSkillsSummary(window, timeoutMilliseconds);
    }
    const readyContent = contentElement(
      window,
      specification.section,
      timeoutMilliseconds
    );
    const readyRole = elementRole(readyContent);
    if (readyRole !== "AXTable" && readyRole !== "AXOutline") {
      skippedSections.push({
        interaction: "sort",
        section: specification.section,
        reason:
          `ready content role ${readyRole || "unknown"} is neither AXTable nor AXOutline`,
      });
      continue;
    }
    for (let iteration = 1; iteration <= iterations; iteration += 1) {
      for (const direction of ["toggle", "restore"]) {
        progress(
          `sorts ${specification.section} ${iteration}/${iterations}: ${direction}`
        );
        const elapsed = measureSort(
          window,
          specification.section,
          specification.header,
          timeoutMilliseconds
        );
        samples.push({
          metric: "sort_input_to_ax_content_ready_ms",
          interaction: `${specification.section} ${specification.header} ${direction}`,
          iteration,
          value_ms: elapsed,
          ax_content_ready_observed: true,
          presentation_observed: true,
          presentation_fidelity: "accessibility_content_ready",
        });
        observedSortSamples += 1;
        progress(
          `sorts ${specification.section} ${iteration}/${iterations}: ` +
          `${direction} ready (${Math.round(elapsed)}ms)`
        );
      }
    }
  }

  if (observedSortSamples === 0) {
    const details = skippedSections
      .map((skipped) => `${skipped.section}: ${skipped.reason}`)
      .join("; ");
    fail(
      "Common interactions observed no real sortable AXTable/AXOutline transition. " +
      `Fixture gap: ${details || "no sortable inventory content was exposed"}.`
    );
  }

  return {
    automation: "macos_accessibility",
    navigation_button_count: buttons.count,
    samples,
    skipped_sections: skippedSections,
    coverage_gaps: [
      "AX content-ready proves SwiftUI exposed the destination state through Accessibility; it does not observe the first painted or composited pixel.",
      ...skippedSections.map(
        (skipped) =>
          `${skipped.section} sort skipped: ${skipped.reason}.`
      ),
    ],
  };
}

function runSkillsCycle(window, iterations, timeoutMilliseconds) {
  const buttons = navigationButtons(window);
  if (!isSelected(buttons.Overview)) {
    selectTabToContentReady(window, buttons.Overview, "Overview", timeoutMilliseconds);
  }
  const samples = [];
  for (let iteration = 1; iteration <= iterations; iteration += 1) {
    const forward = selectTabToContentReady(
      window,
      buttons.Skills,
      "Skills",
      timeoutMilliseconds
    );
    // A persisted non-Summary view already exposes a valid Skills prefix.
    // Normalize through the token-changing helper so that old view cannot be
    // mistaken for the Summary presentation used by this cycle.
    normalizeSkillsSummary(window, timeoutMilliseconds);
    waitForIdentifierPrefix(
      window,
      contentReadyPrefix("Skills"),
      timeoutMilliseconds
    );
    // Keep the fully presented canonical table alive long enough to populate
    // lazy SwiftUI/AppKit allocations before returning to Overview.
    delay(1);
    const backward = selectTabToContentReady(
      window,
      buttons.Overview,
      "Overview",
      timeoutMilliseconds
    );
    samples.push(
      {
        metric: "skills_cycle_selected_state_ms",
        interaction: "Overview to Skills",
        iteration,
        value_ms: forward.selectedStateMilliseconds,
        selected_state_observed: true,
        presentation_observed: true,
      },
      {
        metric: "skills_cycle_selected_state_ms",
        interaction: "Skills to Overview",
        iteration,
        value_ms: backward.selectedStateMilliseconds,
        selected_state_observed: true,
        presentation_observed: false,
      }
    );
  }
  return {
    automation: "macos_accessibility",
    navigation_button_count: buttons.count,
    samples,
    coverage_gaps: [
      "The Skills cycle observes the canonical Summary table through a stable Accessibility identifier, but does not scroll every lazy row into view.",
    ],
  };
}

function runRefresh(window, iterations, timeoutMilliseconds) {
  const buttons = navigationButtons(window);
  if (!isSelected(buttons.Overview)) {
    selectTabToContentReady(window, buttons.Overview, "Overview", timeoutMilliseconds);
  }
  const samples = [];
  for (let iteration = 1; iteration <= iterations; iteration += 1) {
    const control = findReloadControl(window);
    if (!control) {
      fail("Reload is not currently available; wait for existing app work to finish.");
    }
    const started = monotonicMilliseconds();
    press(control);
    let transitionObserved = false;
    waitUntil(() => {
      const current = findReloadControl(window);
      if (!current) {
        transitionObserved = true;
        return false;
      }
      try {
        if (!current.enabled()) {
          transitionObserved = true;
          return false;
        }
      } catch (_) {
        // SwiftUI can replace the accessibility object while the control is
        // still logically ready. A transient read failure is not evidence
        // that Reload left its enabled state; retry until we observe the
        // control missing or disabled and then enabled again.
        return false;
      }
      return transitionObserved;
    }, timeoutMilliseconds, "Reload to leave and return to its enabled ready state");
    samples.push({
      metric: "manual_refresh_to_ready_ms",
      interaction: "Reload",
      iteration,
      value_ms: monotonicMilliseconds() - started,
      ready_state_observed: true,
      transition_observed: transitionObserved,
      presentation_observed: transitionObserved,
    });
  }
  return {
    automation: "macos_accessibility",
    navigation_button_count: buttons.count,
    samples,
    coverage_gaps: [],
  };
}

function waitForProcessState(systemEvents, processName, exists, timeoutMilliseconds) {
  waitUntil(
    () => systemEvents.processes.byName(processName).exists() === exists,
    timeoutMilliseconds,
    `${processName} to ${exists ? "start" : "stop"}`
  );
}

function quitApp(systemEvents, appPath, processName, timeoutMilliseconds) {
  if (!systemEvents.processes.byName(processName).exists()) {
    return;
  }
  Application(appPath).quit();
  waitForProcessState(systemEvents, processName, false, timeoutMilliseconds);
}

function launchToNavigationReady(
  systemEvents,
  appPath,
  processName,
  timeoutMilliseconds
) {
  const started = monotonicMilliseconds();
  Application(appPath).activate();
  waitForProcessState(systemEvents, processName, true, timeoutMilliseconds);
  const process = processFor(systemEvents, processName);
  const window = mainWindow(process, timeoutMilliseconds);
  const buttons = navigationButtons(window);
  return {
    value_ms: monotonicMilliseconds() - started,
    navigation_button_count: buttons.count,
  };
}

function runLaunch(
  systemEvents,
  appPath,
  processName,
  scenario,
  iterations,
  timeoutMilliseconds
) {
  if (scenario === "launch-cold" && iterations !== 1) {
    fail("launch-cold requires exactly one iteration; every later launch would be warm.");
  }
  if (scenario === "launch-cold" && systemEvents.processes.byName(processName).exists()) {
    fail(
      `${processName} must be stopped before launch-cold. The harness will not call a running launch cold.`
    );
  }
  const samples = [];
  let navigationButtonCount = null;
  if (scenario === "launch-warm") {
    quitApp(systemEvents, appPath, processName, timeoutMilliseconds);
    launchToNavigationReady(systemEvents, appPath, processName, timeoutMilliseconds);
    quitApp(systemEvents, appPath, processName, timeoutMilliseconds);
  }
  for (let iteration = 1; iteration <= iterations; iteration += 1) {
    const measured = launchToNavigationReady(
      systemEvents,
      appPath,
      processName,
      timeoutMilliseconds
    );
    navigationButtonCount = measured.navigation_button_count;
    samples.push({
      metric:
        scenario === "launch-warm"
          ? "warm_launch_to_navigation_ready_ms"
          : "cold_launch_to_navigation_ready_ms",
      interaction: scenario,
      iteration,
      value_ms: measured.value_ms,
      navigation_ready_observed: true,
      presentation_observed: true,
      os_cache_state_controlled: false,
    });
    if (iteration < iterations) {
      quitApp(systemEvents, appPath, processName, timeoutMilliseconds);
    }
  }
  return {
    automation: "macos_accessibility",
    navigation_button_count: navigationButtonCount,
    samples,
    coverage_gaps: [
      "The harness proves a stopped process reached an Accessibility-ready main window but cannot flush or prove macOS filesystem and dynamic-linker cache state.",
    ],
  };
}

function run(argv) {
  if (argv.length !== 5) {
    fail("Expected app path, process name, scenario, iterations, and timeout milliseconds.");
  }
  const appPath = argv[0];
  const processName = argv[1];
  const scenario = argv[2];
  const iterations = Number(argv[3]);
  const timeoutMilliseconds = Number(argv[4]);
  const systemEvents = Application("System Events");
  let result;
  if (scenario === "launch-warm" || scenario === "launch-cold") {
    result = runLaunch(
      systemEvents,
      appPath,
      processName,
      scenario,
      iterations,
      timeoutMilliseconds
    );
  } else {
    const process = processFor(systemEvents, processName);
    const window = mainWindow(process, timeoutMilliseconds);
    if (scenario === "tabs") {
      result = runTabs(window, iterations, timeoutMilliseconds);
    } else if (scenario === "common-interactions") {
      result = runCommonInteractions(
        process,
        window,
        iterations,
        timeoutMilliseconds
      );
    } else if (scenario === "skills-cycle") {
      result = runSkillsCycle(window, iterations, timeoutMilliseconds);
    } else if (scenario === "refresh") {
      result = runRefresh(window, iterations, timeoutMilliseconds);
    } else {
      fail(`Unsupported interaction scenario: ${scenario}`);
    }
  }
  return JSON.stringify({
    schema_version: 1,
    scenario,
    process_name: processName,
    ...result,
  });
}
