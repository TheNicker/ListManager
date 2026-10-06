(function (global) {
  function isValidDateValue(value) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
    const date = new Date(`${value}T00:00:00Z`);
    return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
  }

  function formatDate(dateString) {
    if (!dateString) return '—';
    const date = new Date(`${dateString}T00:00:00Z`);
    if (Number.isNaN(date.getTime())) return String(dateString);
    return date.toLocaleDateString('he-IL', { day: '2-digit', month: 'short', year: 'numeric' });
  }

  function formatNumber(value) {
    return Number.isFinite(value) ? Number(value).toFixed(2) : '0.00';
  }

  function createMoneyFormatter(currency, locale) {
    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
  }

  function cryptoId(prefix) {
    const random = Math.random().toString(36).slice(2, 10);
    return `${prefix}-${Date.now()}-${random}`;
  }

  global.Utils = {
    isValidDateValue,
    formatDate,
    formatNumber,
    createMoneyFormatter,
    cryptoId
  };
})(window);