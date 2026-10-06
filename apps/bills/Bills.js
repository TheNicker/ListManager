(function (global) {
  const { isValidDateValue, formatDate, formatNumber } = global.Utils;
  const escapeHtml = global.escapeHtml;

  const UTILITIES = {
    water: {
      label: 'מים',
      priceFields: ['averagePrice'],
      computeTotal: (usage, entry) => usage * (entry.averagePrice || 0)
    },
    electricity: {
      label: 'חשמל',
      priceFields: ['pricePerUnit', 'fixedPrice'],
      computeTotal: (usage, entry) => usage * (entry.pricePerUnit || 0) + (entry.fixedPrice || 0)
    }
  };

  function createBills(options = {}) {
    let moneyFormatter = options.moneyFormatter;
    let priceFormatter = options.priceFormatter;

    function setFormatters(money, price) {
      moneyFormatter = money;
      priceFormatter = price;
    }

    function formatMoney(value) {
      return moneyFormatter.format(Number(value || 0));
    }

    function formatPrice(value) {
      return priceFormatter.format(Number(value || 0));
    }

    function formatOptionalMoney(value) {
      return value == null ? '—' : formatMoney(value);
    }

    function getUtilityLabel(kind) {
      return UTILITIES[kind].label;
    }

    function sumTotals(rows) {
      return rows.reduce((total, row) => total + (row.totalAmount ?? 0), 0);
    }

    function getSortedEntries(person, kind, excludeId = null) {
      return [...(person?.[kind] || [])]
        .filter(entry => entry.id !== excludeId)
        .sort((a, b) => new Date(a.date) - new Date(b.date));
    }

    function isBaselineDate(person, kind, date, excludeId = null) {
      const existing = getSortedEntries(person, kind, excludeId);
      if (!existing.length) return true;
      return isValidDateValue(date) && date < existing[0].date;
    }

    function earliestReadingDate(person, kind, excludeId = null) {
      return getSortedEntries(person, kind, excludeId).reduce(
        (earliest, entry) => entry.date < earliest ? entry.date : earliest,
        '9999-12-31'
      );
    }

    function isFirstReading(person, kind, id) {
      return getSortedEntries(person, kind)[0]?.id === id;
    }

    function getLastEntry(person, kind) {
      const entries = getSortedEntries(person, kind);
      return entries[entries.length - 1] || null;
    }

    function computeRows(person, kind) {
      const config = UTILITIES[kind];
      const rows = getSortedEntries(person, kind);
      return rows.map((entry, index) => {
        const previousRead = index === 0 ? null : rows[index - 1].read;
        const usage = previousRead === null ? null : Math.max(0, Number(entry.read) - previousRead);
        const totalAmount = usage === null ? null : config.computeTotal(usage, entry);
        return { ...entry, isFirst: index === 0, previousRead, usage, totalAmount };
      });
    }

    function buildCombinedPeriods(waterRows, electricityRows) {
      const periods = new Map();
      for (const row of waterRows) {
        if (!periods.has(row.date)) {
          periods.set(row.date, { date: row.date, waterTotal: row.totalAmount, electricityTotal: 0, hasElectricity: false });
        }
      }
      for (const row of electricityRows) {
        const period = periods.get(row.date);
        if (period) {
          if (!period.hasElectricity) {
            period.electricityTotal = row.totalAmount;
            period.hasElectricity = true;
          }
        } else {
          periods.set(row.date, { date: row.date, waterTotal: 0, electricityTotal: row.totalAmount, hasElectricity: true });
        }
      }
      return [...periods.values()]
        .sort((left, right) => right.date.localeCompare(left.date))
        .map(({ hasElectricity, ...period }) => ({ ...period, total: (period.waterTotal ?? 0) + (period.electricityTotal ?? 0) }));
    }

    function checkMeterReset(person, kind, newRead) {
      const lastEntry = getLastEntry(person, kind);
      if (lastEntry && Number.isFinite(lastEntry.read) && newRead < lastEntry.read) {
        return `ערך הקריאה החדש (${newRead}) נמוך מהקריאה הקודמת (${lastEntry.read}).\nזה עשוי להצביע על כך שהמונה אופס. האם להמשיך בכל זאת?`;
      }
      return null;
    }

    function validateReadingPayload(payload, kind, isBaseline) {
      if (!isValidDateValue(payload.date) || !Number.isFinite(payload.read)) return false;
      if (!isBaseline) {
        for (const field of UTILITIES[kind].priceFields) {
          if (!Number.isFinite(payload[field]) || payload[field] < 0) return false;
        }
      }
      return true;
    }

    function renderReadingRow(row, kind, isEditing) {
      const config = UTILITIES[kind];
      const prevDisplay = row.previousRead === null
        ? '—'
        : `${formatNumber(row.previousRead)}${kind === 'electricity' ? ' kWh' : ''}`;
      const usageDisplay = row.usage === null
        ? '—'
        : `${formatNumber(row.usage)}${kind === 'electricity' ? ' kWh' : ''}`;

      if (isEditing) {
        const dateInput = `<input class="edit-entry-input" data-field="date" type="date" lang="en" dir="ltr" value="${escapeHtml(row.date)}" required aria-label="תאריך">`;
        const readInput = `<input class="edit-entry-input" data-field="read" type="number" min="0" step="0.01" value="${escapeHtml(row.read)}" required aria-label="קריאה">`;
        const rateInput = row.isFirst
          ? '—'
          : `<input class="edit-entry-input" data-field="${config.priceFields[0]}" type="number" min="0" step="any" value="${escapeHtml(row[config.priceFields[0]])}" required aria-label="מחיר">`;
        const fixedInput = kind === 'electricity' && !row.isFirst
          ? `<input class="edit-entry-input" data-field="fixedPrice" type="number" min="0" step="any" value="${escapeHtml(row.fixedPrice)}" required aria-label="תשלום קבוע">`
          : '—';
        const actions = `<td><div class="action-cluster"><button class="primary-button" type="button" data-action="save-entry-edit">שמור</button><button class="ghost-button" type="button" data-action="cancel-entry-edit">ביטול</button></div></td>`;
        const usageCell = `<td>${row.usage === null ? '—' : formatNumber(row.usage)}</td>`;
        const amountCell = `<td class="amount">${formatOptionalMoney(row.totalAmount)}</td>`;
        if (kind === 'water') {
          return `<tr><td>${dateInput}</td><td>${readInput}</td><td>${prevDisplay}</td><td>${usageDisplay}</td><td>${rateInput}</td>${usageCell}${amountCell}${actions}</tr>`;
        }
        return `<tr><td>${dateInput}</td><td>${readInput}</td><td>${prevDisplay}</td><td>${usageDisplay}</td><td>${rateInput}</td><td>${fixedInput}</td>${amountCell}${actions}</tr>`;
      }

      const readValue = `${formatNumber(row.read)}${kind === 'electricity' ? ' kWh' : ''}`;
      const rate = row.isFirst ? '—' : formatPrice(kind === 'water' ? row.averagePrice : row.pricePerUnit);
      const extraCell = kind === 'electricity'
        ? `<td>${row.isFirst ? '—' : formatMoney(row.fixedPrice)}</td>`
        : `<td>${row.usage === null ? '—' : formatNumber(row.usage)}</td>`;
      const editAction = kind === 'water' ? 'edit-water' : 'edit-electricity';
      const removeAction = kind === 'water' ? 'remove-water' : 'remove-electricity';
      return `<tr>
        <td>${formatDate(row.date)}</td>
        <td>${readValue}</td>
        <td>${prevDisplay}</td>
        <td>${usageDisplay}</td>
        <td>${rate}</td>
        ${extraCell}
        <td class="amount">${formatOptionalMoney(row.totalAmount)}</td>
        <td><div class="action-cluster">
          <button class="ghost-button" type="button" data-action="${editAction}" data-id="${escapeHtml(row.id)}" aria-label="ערוך קריאה">ערוך</button>
          <button class="danger-button" type="button" data-action="${removeAction}" data-id="${escapeHtml(row.id)}">הסר</button>
        </div></td>
      </tr>`;
    }

    function renderFilterIndicator(element, kind, activeDate) {
      element.classList.toggle('hidden', !activeDate);
      element.innerHTML = activeDate
        ? `מסנן פעיל: ${formatDate(activeDate)} <button type="button" data-action="clear-${kind}-filter">בטל מסנן</button>`
        : '';
    }

  return {
    setFormatters,
    formatMoney,
    formatOptionalMoney,
    getUtilityLabel,
    sumTotals,
    isBaselineDate,
      earliestReadingDate,
      isFirstReading,
      computeRows,
      buildCombinedPeriods,
      checkMeterReset,
      validateReadingPayload,
      renderReadingRow,
      renderFilterIndicator
    };
  }

  global.Bills = { create: createBills };
})(window);