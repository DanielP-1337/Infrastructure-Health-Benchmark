(function (global) {
  'use strict';

  function clamp(v, min, max) { return Math.max(min, Math.min(max, v)); }

  function lowerIsBetter(value, good, warning) {
    if (value == null || !isFinite(value)) return null;
    if (value <= good) return 100;
    if (value >= warning * 2) return 10;
    if (value <= warning) return Math.round(100 - ((value - good) / (warning - good)) * 40);
    return Math.round(60 - ((value - warning) / warning) * 50);
  }

  function higherIsBetter(value, good, warning) {
    if (value == null || !isFinite(value)) return null;
    if (value >= good) return 100;
    if (value <= warning / 2) return 10;
    if (value >= warning) return Math.round(60 + ((value - warning) / (good - warning)) * 40);
    return Math.round(10 + ((value - warning / 2) / (warning / 2)) * 50);
  }

  function average(values) {
    var valid = values.filter(function (x) { return x != null && isFinite(x); });
    if (!valid.length) return null;
    return valid.reduce(function (a, b) { return a + b; }, 0) / valid.length;
  }

  function overall(componentScores) {
    var valid = componentScores.filter(function (x) { return x != null && isFinite(x); });
    if (!valid.length) return null;
    var min = Math.min.apply(Math, valid);
    var avg = average(valid);
    return Math.round(clamp(min * 0.65 + avg * 0.35, 0, 100));
  }

  function label(score) {
    if (score == null) return { text: 'WAITING FOR DATA', cls: 'pending' };
    if (score >= 85) return { text: 'EXCELLENT', cls: 'good' };
    if (score >= 70) return { text: 'GOOD', cls: 'good' };
    if (score >= 50) return { text: 'DEGRADED', cls: 'warn' };
    return { text: 'POOR', cls: 'bad' };
  }

  global.IHBScoring = {
    lowerIsBetter: lowerIsBetter,
    higherIsBetter: higherIsBetter,
    average: average,
    overall: overall,
    label: label
  };
})(window);
