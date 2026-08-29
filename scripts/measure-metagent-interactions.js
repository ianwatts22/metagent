ObjC.import("stdlib");
ObjC.import("Foundation");

function fail(message) {
  throw new Error(message);
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

function elementSize(element) {
  try {
    return element.size();
  } catch (_) {
    return [0, 0];
  }
}

function elementPosition(element) {
  try {
    return element.position();
  } catch (_) {
    return [0, 0];
  }
}

function navigationButtons(window) {
  const topLevel = window.uiElements()[0];
  if (!topLevel) {
    fail("The Metagent window has no top-level Accessibility group.");
  }
  const candidates = topLevel.uiElements().filter((element) => {
    const size = elementSize(element);
    return elementRole(element) === "AXButton" && size[0] >= 60 && size[1] <= 40;
  });
  const rows = new Map();
  for (const element of candidates) {
    const y = Math.round(elementPosition(element)[1]);
    const row = rows.get(y) || [];
    row.push(element);
    rows.set(y, row);
  }
  const possibleNavigationRows = Array.from(rows.values()).filter((row) => {
    if (row.length !== 5 && row.length !== 6) {
      return false;
    }
    const widths = row.map((element) => elementSize(element)[0]);
    const heights = row.map((element) => elementSize(element)[1]);
    return (
      Math.max(...widths) - Math.min(...widths) <= 2 &&
      Math.max(...heights) - Math.min(...heights) <= 2
    );
  });
  if (possibleNavigationRows.length !== 1) {
    fail(
      `Expected one equal-sized five- or six-button navigation row; found ${possibleNavigationRows.length}. ` +
      "The app Accessibility shape may have changed."
    );
  }
  return possibleNavigationRows[0].sort(
    (left, right) => elementPosition(left)[0] - elementPosition(right)[0]
  );
}

function namedNavigation(buttons) {
  // History may still be present between Overview and Skills. Anchoring the
  // four inventory destinations from the right keeps this harness valid after
  // History is removed without pretending unlabeled AX buttons have names.
  return {
    Overview: buttons[0],
    Skills: buttons[buttons.length - 4],
    MCPs: buttons[buttons.length - 3],
    Plugins: buttons[buttons.length - 2],
    Projects: buttons[buttons.length - 1],
  };
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
  const tabs = namedNavigation(buttons);
  if (!isSelected(tabs.Overview)) {
    selectTab(tabs.Overview, timeoutMilliseconds, "Overview");
  }
  const samples = [];
  const destinations = ["Skills", "MCPs", "Plugins", "Projects"];
  for (let iteration = 1; iteration <= iterations; iteration += 1) {
    for (const destination of destinations) {
      const forward = selectTab(tabs[destination], timeoutMilliseconds, destination);
      samples.push({
        metric: "tab_input_to_selected_state_ms",
        interaction: `Overview to ${destination}`,
        iteration,
        value_ms: forward,
        selected_state_observed: true,
        presentation_observed: false,
      });
      const backward = selectTab(tabs.Overview, timeoutMilliseconds, "Overview");
      samples.push({
        metric: "tab_input_to_selected_state_ms",
        interaction: `${destination} to Overview`,
        iteration,
        value_ms: backward,
        selected_state_observed: true,
        presentation_observed: false,
      });
    }
  }
  return {
    automation: "macos_accessibility",
    navigation_button_count: buttons.length,
    samples,
    coverage_gaps: [
      "SwiftUI exposes selected state but no stable view-specific ready sentinel; tab results are input-to-selected-state, not input-to-present.",
      "Filter and sort input-to-present remain unmeasured until stable Accessibility identifiers or UI-test hooks exist.",
    ],
  };
}

function runRefresh(window, iterations, timeoutMilliseconds) {
  const buttons = navigationButtons(window);
  const tabs = namedNavigation(buttons);
  if (!isSelected(tabs.Overview)) {
    selectTab(tabs.Overview, timeoutMilliseconds, "Overview");
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
        transitionObserved = true;
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
    navigation_button_count: buttons.length,
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
    navigation_button_count: buttons.length,
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
