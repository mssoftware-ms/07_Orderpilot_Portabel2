/// Account screen — Welle B4.4.
///
/// Five vertically stacked cards backed by [BitunixConnectionProvider]:
///   * Credentials-Card: API-Key + Secret entry, Save & Connect, Clear.
///   * Connection-Status-Card: status indicator, Test Connection (refresh),
///     last sync timestamp, error banner.
///   * Balance-Card: available / margin / unrealized PnL, only when
///     connected and a balance is loaded.
///   * Positions-Card: DataTable of open positions, only when connected.
///   * Live-Trading-Card: an **eligibility-gated** switch. Interactable iff
///     all three [LiveModeEligibility] conjuncts pass; flipping it ON pops
///     a confirm dialog spelling out the real-money implication, flipping
///     OFF skips the dialog (safety-first). A post-frame auto-disable hook
///     flips the toggle back off the moment any eligibility gate breaks
///     (kill-switch activated, exchange disconnected, caps cleared).
///     [BitunixClient.placeOrder] / [BitunixClient.cancelOrder] still throw
///     [LiveTradingDisabledException] — order routing lands in P4P Step-2.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models/bitunix_models.dart';
import '../../features/exchange/bitunix_connection_provider.dart';
import '../../features/paper/paper_trading_provider.dart';
import '../../features/risk/live_mode_eligibility.dart';
import '../../features/risk/risk_assessment.dart';
import '../../features/risk/risk_config.dart';
import '../../features/risk/risk_manager.dart';
import '../../services/bitunix_auth.dart';
import '../themes/app_theme.dart';

const String _kLiveDisabledTooltip =
    'Live trading requires all three eligibility checkmarks below: '
    'risk limits configured, exchange connected, kill-switch inactive.';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  bool _obscureSecret = true;

  /// Welle B4.3-3: pending Risk-Limits state. `null` while the on-screen
  /// sliders mirror the persisted config; non-null once the user drags any
  /// slider. Clearing happens on a successful Save and on any kill-switch
  /// state change so external mutations (e.g. activate / reset) re-sync the
  /// UI to the freshest persisted values.
  RiskConfig? _pendingRiskConfig;

  @override
  void dispose() {
    _apiKeyController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _onSaveAndConnect() async {
    final apiKey = _apiKeyController.text.trim();
    final secret = _secretController.text.trim();
    if (apiKey.isEmpty || secret.isEmpty) return;
    final provider = context.read<BitunixConnectionProvider>();
    await provider.connect(
      BitunixCredentials(apiKey: apiKey, secret: secret),
    );
  }

  Future<void> _onClear() async {
    _apiKeyController.clear();
    _secretController.clear();
    await context.read<BitunixConnectionProvider>().clearStoredCredentials();
  }

  Future<void> _onTestConnection() async {
    await context.read<BitunixConnectionProvider>().refresh();
  }

  // ─── Risk-Limits handlers (Welle B4.3-3) ────────────────────────────────

  RiskConfig _displayedRiskConfig(RiskManager rm) =>
      _pendingRiskConfig ?? rm.config;

  void _setPendingRisk(RiskConfig next, RiskManager rm) {
    if (next == rm.config) {
      if (_pendingRiskConfig == null) return;
      setState(() => _pendingRiskConfig = null);
      return;
    }
    setState(() => _pendingRiskConfig = next);
  }

  Future<void> _onSaveRiskLimits() async {
    final pending = _pendingRiskConfig;
    if (pending == null) return;
    await context.read<RiskManager>().saveConfig(pending);
    if (!mounted) return;
    setState(() => _pendingRiskConfig = null);
  }

  Future<void> _onResetKillSwitch() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const Key('account_reset_kill_switch_dialog'),
        backgroundColor: AppColors.surfaceCard,
        title: const Row(
          children: [
            Icon(Icons.lock_open, color: AppColors.warningAmber),
            SizedBox(width: 8),
            Text('Reset Kill Switch?'),
          ],
        ),
        content: const Text(
          'Resetting clears the global trading block. Make sure you have '
          'reviewed the breach reason before re-enabling trading.\n\n'
          'Proceed?',
        ),
        actions: [
          TextButton(
            key: const Key('account_reset_kill_switch_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            key: const Key('account_reset_kill_switch_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.lock_open, size: 16),
            label: const Text('Reset Kill Switch'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await context.read<RiskManager>().resetKillSwitch();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BitunixConnectionProvider>(
      builder: (context, provider, _) {
        final risk = context.watch<RiskManager>();
        final paper = context.watch<PaperTradingProvider>();
        final eligibility = LiveModeEligibility.evaluate(
          riskManager: risk,
          exchangeProvider: provider,
        );

        // Welle B4.4: auto-disable hook. If live trading was turned on but
        // any eligibility gate has dropped (kill switch activated, exchange
        // disconnected, caps cleared) flip it back off after this frame
        // commits. State mutation in `build` is illegal — the post-frame
        // callback hops out of the current frame so the listener tree can
        // settle before `disableLiveTrading` notifies again.
        if (risk.config.liveTradingEnabled && !eligibility.isEligible) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            risk.disableLiveTrading(reason: 'Eligibility lost');
          });
        }

        return Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context),
                  const SizedBox(height: 16),
                  _credentialsCard(context, provider),
                  const SizedBox(height: 12),
                  _statusCard(context, provider),
                  if (provider.status == BitunixConnectionStatus.connected &&
                      provider.balance != null) ...[
                    const SizedBox(height: 12),
                    _balanceCard(context, provider.balance!),
                  ],
                  if (provider.status == BitunixConnectionStatus.connected) ...[
                    const SizedBox(height: 12),
                    _positionsCard(context, provider.positions),
                  ],
                  const SizedBox(height: 12),
                  _liveTradingCard(context, provider, risk, eligibility),
                  const SizedBox(height: 12),
                  _riskLimitsCard(context, risk),
                  const SizedBox(height: 12),
                  _riskStatusCard(context, risk, paper),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Account',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Bitunix futures connector — read-only sync of balance, '
                  'positions and pending orders.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _credentialsCard(
      BuildContext context, BitunixConnectionProvider provider) {
    final hasStored = provider.hasCredentials;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('API Credentials'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('account_api_key_field'),
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'Paste your Bitunix API key',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('account_secret_field'),
              controller: _secretController,
              obscureText: _obscureSecret,
              decoration: InputDecoration(
                labelText: 'Secret',
                hintText: 'Paste your Bitunix API secret',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const Key('account_secret_visibility_toggle'),
                  icon: Icon(
                    _obscureSecret ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _obscureSecret = !_obscureSecret),
                  tooltip: _obscureSecret ? 'Show secret' : 'Hide secret',
                ),
              ),
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  key: const Key('account_save_connect_button'),
                  onPressed: provider.status ==
                          BitunixConnectionStatus.connecting
                      ? null
                      : _onSaveAndConnect,
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Save & Connect'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const Key('account_clear_credentials_button'),
                  onPressed: hasStored ? _onClear : null,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Clear stored'),
                ),
              ],
            ),
            if (hasStored && _apiKeyController.text.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Stored credentials detected — leave fields empty and '
                  'press "Test Connection" below to use them.',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(
      BuildContext context, BitunixConnectionProvider provider) {
    final (label, color, icon) = _statusVisuals(provider.status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Connection'),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  key: const Key('account_status_label'),
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  key: const Key('account_test_connection_button'),
                  onPressed: provider.status ==
                              BitunixConnectionStatus.connecting ||
                          !provider.hasCredentials
                      ? null
                      : _onTestConnection,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Test Connection'),
                ),
              ],
            ),
            if (provider.lastSyncAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Last sync: ${_formatTimestamp(provider.lastSyncAt!)}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            if (provider.errorMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('account_error_banner'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.bearRed.withValues(alpha: 0.12),
                  border: Border.all(
                      color: AppColors.bearRed.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  provider.errorMessage!,
                  style: const TextStyle(
                    color: AppColors.bearRed,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _balanceCard(BuildContext context, BitunixBalance balance) {
    return Card(
      key: const Key('account_balance_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Balance (${balance.marginCoin})'),
            const SizedBox(height: 12),
            _kv('Available', _formatNumber(balance.available)),
            _kv('Frozen', _formatNumber(balance.frozen)),
            _kv('Margin (positions)', _formatNumber(balance.margin)),
            _kv('Transferable', _formatNumber(balance.transfer)),
            _kv(
              'Unrealized PnL (total)',
              _formatNumber(balance.totalUnrealizedPNL),
              color: balance.totalUnrealizedPNL >= 0
                  ? AppColors.bullGreen
                  : AppColors.bearRed,
            ),
            if (balance.positionMode.isNotEmpty)
              _kv('Position mode', balance.positionMode),
          ],
        ),
      ),
    );
  }

  Widget _positionsCard(
      BuildContext context, List<BitunixPosition> positions) {
    return Card(
      key: const Key('account_positions_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Open Positions (${positions.length})'),
            const SizedBox(height: 12),
            if (positions.isEmpty)
              const Text(
                'No open positions.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingTextStyle: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  dataTextStyle: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                  columns: const [
                    DataColumn(label: Text('Symbol')),
                    DataColumn(label: Text('Side')),
                    DataColumn(label: Text('Qty'), numeric: true),
                    DataColumn(label: Text('Entry'), numeric: true),
                    DataColumn(label: Text('Lev')),
                    DataColumn(label: Text('Unrealized PnL'), numeric: true),
                  ],
                  rows: positions
                      .map((p) => DataRow(cells: [
                            DataCell(Text(p.symbol)),
                            DataCell(Text(_sideLabel(p.side))),
                            DataCell(Text(_formatNumber(p.qty))),
                            DataCell(Text(_formatNumber(p.avgOpenPrice))),
                            DataCell(Text(p.leverage?.toString() ?? '—')),
                            DataCell(Text(
                              _formatNumber(p.unrealizedPNL),
                              style: TextStyle(
                                color: (p.unrealizedPNL ?? 0) >= 0
                                    ? AppColors.bullGreen
                                    : AppColors.bearRed,
                              ),
                            )),
                          ]))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _liveTradingCard(
      BuildContext context,
      BitunixConnectionProvider provider,
      RiskManager risk,
      LiveModeEligibility eligibility) {
    final liveEnabled = risk.config.liveTradingEnabled;
    // CRITICAL: onChanged is non-null iff *all three* eligibility conjuncts
    // pass. The widget tests pin this — anyone who lights the switch up
    // without going through `eligibility.isEligible` is a regression that
    // must surface immediately.
    final ValueChanged<bool>? onChanged = eligibility.isEligible
        ? (v) => _handleLiveToggle(context, risk, v)
        : null;
    return Card(
      key: const Key('account_live_trading_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _sectionTitle('Live Trading')),
                _liveTradingStatusPill(liveEnabled, eligibility.isEligible),
              ],
            ),
            const SizedBox(height: 4),
            Tooltip(
              key: const Key('account_live_trading_tooltip'),
              message: _kLiveDisabledTooltip,
              child: SwitchListTile(
                key: const Key('account_live_trading_switch'),
                title: const Text('Enable live order routing'),
                subtitle: Text(
                  eligibility.isEligible
                      ? 'All eligibility checks pass. Flipping ON requires '
                          'an explicit confirmation.'
                      : 'Disabled — see the eligibility checklist below for '
                          'what is still missing.',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
                value: liveEnabled,
                onChanged: onChanged,
              ),
            ),
            const SizedBox(height: 8),
            _eligibilityReadout(eligibility),
            // Belt-and-braces: surface the provider-side flag so a
            // developer who flips the persisted bit by hand can see the
            // dependency. The provider getter is no longer the gate (the
            // switch's onChanged is), but the value is informative.
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 12),
              child: Text(
                'provider.liveTradingEnabled = '
                '${provider.liveTradingEnabled}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _liveTradingStatusPill(bool liveEnabled, bool isEligible) {
    final (label, color) = liveEnabled
        ? ('LIVE', AppColors.bullGreen)
        : isEligible
            ? ('Ready', AppColors.accentCyan)
            : ('Locked', AppColors.warningAmber);
    return Container(
      key: const Key('account_live_trading_pill'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Welle B4.4 — Live-toggle dispatch.
  ///
  /// `target == false` is the safety path: flips OFF immediately without
  /// any dialog, so a user yanking back from live mode is never blocked.
  ///
  /// `target == true` is the danger path: a non-dismissible confirm dialog
  /// spells out the real-money implication. Only an explicit "Activate"
  /// click reaches [RiskManager.enableLiveTrading]; tapping outside or
  /// hitting Cancel leaves the persisted state untouched.
  Future<void> _handleLiveToggle(
      BuildContext context, RiskManager risk, bool target) async {
    if (!target) {
      await risk.disableLiveTrading(reason: 'manual');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const Key('account_enable_live_trading_dialog'),
        backgroundColor: AppColors.surfaceCard,
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.warningAmber),
            SizedBox(width: 8),
            Expanded(child: Text('Activate Live Trading?')),
          ],
        ),
        content: const Text(
          'This will enable real-money trading on Bitunix Futures.\n\n'
          'Before continuing, confirm you understand:\n'
          '  • The Risk-Layer guards (position risk, daily loss, drawdown, '
          'consecutive losses) are configured and will block trades that '
          'breach the caps.\n'
          '  • The kill switch is currently inactive — trades can fire.\n'
          '  • Strategy signals will be routed to Bitunix via authenticated '
          'API calls. You are responsible for the outcomes.',
        ),
        actions: [
          TextButton(
            key: const Key('account_enable_live_trading_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            key: const Key('account_enable_live_trading_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.bolt, size: 16),
            label: const Text('Activate Live Trading'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warningAmber,
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await risk.enableLiveTrading();
  }

  Widget _eligibilityReadout(LiveModeEligibility e) {
    return Container(
      key: const Key('account_live_mode_eligibility'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Prerequisites for the future live toggle',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 6),
          _eligibilityRow(
            testKey: 'eligibility_risk_limits',
            label: 'Risk limits configured',
            active: e.allRiskGatesActive,
          ),
          _eligibilityRow(
            testKey: 'eligibility_exchange',
            label: 'Exchange connected',
            active: e.exchangeConnected,
          ),
          _eligibilityRow(
            testKey: 'eligibility_kill_switch',
            label: 'Kill-switch inactive',
            active: e.killSwitchInactive,
          ),
        ],
      ),
    );
  }

  Widget _eligibilityRow({
    required String testKey,
    required String label,
    required bool active,
  }) {
    final color = active ? AppColors.bullGreen : AppColors.warningAmber;
    return Padding(
      key: Key(testKey),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            active ? Icons.check_circle : Icons.cancel,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Risk Limits (Welle B4.3-3) ────────────────────────────────────────

  Widget _riskLimitsCard(BuildContext context, RiskManager risk) {
    final displayed = _displayedRiskConfig(risk);
    final dirty = _pendingRiskConfig != null;
    return Card(
      key: const Key('account_risk_limits_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Risk Limits'),
            const SizedBox(height: 4),
            const Text(
              'Limits gate every position open (paper today, live in a '
              'future wave).',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _riskSlider(
              key: const Key('risk_slider_max_position'),
              label: 'Max position risk',
              value: displayed.maxPositionRiskPct,
              min: 0.5,
              max: 10,
              divisions: 19,
              format: (v) => '${v.toStringAsFixed(1)} %',
              onChanged: (v) => _setPendingRisk(
                  displayed.copyWith(maxPositionRiskPct: v), risk),
            ),
            _riskSlider(
              key: const Key('risk_slider_daily_loss'),
              label: 'Max daily loss',
              value: displayed.maxDailyLossPct,
              min: 1,
              max: 10,
              divisions: 18,
              format: (v) => '${v.toStringAsFixed(1)} %',
              onChanged: (v) => _setPendingRisk(
                  displayed.copyWith(maxDailyLossPct: v), risk),
            ),
            _riskSlider(
              key: const Key('risk_slider_drawdown'),
              label: 'Max drawdown',
              value: displayed.maxDrawdownPct,
              min: 5,
              max: 30,
              divisions: 25,
              format: (v) => '${v.toStringAsFixed(0)} %',
              onChanged: (v) => _setPendingRisk(
                  displayed.copyWith(maxDrawdownPct: v), risk),
            ),
            _riskSlider(
              key: const Key('risk_slider_consec_losses'),
              label: 'Max consec losses',
              value: displayed.maxConsecutiveLosses.toDouble(),
              min: 3,
              max: 15,
              divisions: 12,
              format: (v) => v.toStringAsFixed(0),
              onChanged: (v) => _setPendingRisk(
                  displayed.copyWith(maxConsecutiveLosses: v.round()), risk),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  key: const Key('account_save_risk_limits_button'),
                  onPressed: dirty ? _onSaveRiskLimits : null,
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Save Risk Limits'),
                ),
                if (dirty) ...[
                  const SizedBox(width: 12),
                  TextButton(
                    key: const Key('account_discard_risk_limits_button'),
                    onPressed: () =>
                        setState(() => _pendingRiskConfig = null),
                    child: const Text('Discard'),
                  ),
                ],
              ],
            ),
            if (dirty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Unsaved changes — Save to persist or Discard to revert.',
                  style:
                      TextStyle(color: AppColors.warningAmber, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _riskSlider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: AppColors.accentCyan,
                inactiveTrackColor: AppColors.border,
                thumbColor: AppColors.accentCyan,
                overlayColor: AppColors.accentCyan.withAlpha(30),
              ),
              child: Slider(
                key: key,
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              format(value),
              style: const TextStyle(
                  color: AppColors.accentCyan,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _riskStatusCard(
      BuildContext context, RiskManager risk, PaperTradingProvider paper) {
    final session = paper.session;
    final assessment = session == null
        ? RiskAssessment(
            currentDailyPnlPct: 0,
            currentDrawdownPct: 0,
            currentConsecutiveLosses: 0,
            killSwitchActive: risk.killSwitchActive,
            breachedGates: risk.killSwitchActive
                ? const {RiskGate.killSwitch}
                : const <RiskGate>{},
          )
        : risk.assess(session);
    return Card(
      key: const Key('account_risk_status_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Risk Status'),
            const SizedBox(height: 4),
            Text(
              session == null
                  ? 'No active paper session — values reflect the persisted '
                      'kill-switch state only.'
                  : 'Live values from the active paper session.',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              childAspectRatio: 3.0,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                _riskMiniCard(
                  testKey: 'risk_status_daily_pnl',
                  label: 'Daily PnL',
                  value: '${assessment.currentDailyPnlPct.toStringAsFixed(2)} %',
                  breached: assessment.gateBreached(RiskGate.dailyLoss),
                ),
                _riskMiniCard(
                  testKey: 'risk_status_drawdown',
                  label: 'Drawdown',
                  value:
                      '${assessment.currentDrawdownPct.toStringAsFixed(2)} %',
                  breached: assessment.gateBreached(RiskGate.drawdown),
                ),
                _riskMiniCard(
                  testKey: 'risk_status_consec_losses',
                  label: 'Consec losses',
                  value: '${assessment.currentConsecutiveLosses}',
                  breached:
                      assessment.gateBreached(RiskGate.consecutiveLosses),
                ),
                _riskMiniCard(
                  testKey: 'risk_status_kill_switch',
                  label: 'Kill switch',
                  value: risk.killSwitchActive ? 'ACTIVE' : 'inactive',
                  breached: risk.killSwitchActive,
                ),
              ],
            ),
            // Welle B4.3-4: Reset button surfaces only when the kill switch
            // is actively tripped. A ConfirmDialog gates the reset itself,
            // and the persisted state means a misclick can't silently undo
            // a manual trip from a sister screen.
            if (risk.killSwitchActive) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    key: const Key('account_reset_kill_switch_button'),
                    onPressed: _onResetKillSwitch,
                    icon: const Icon(Icons.lock_open, size: 16),
                    label: const Text('Reset Kill Switch'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.warningAmber,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _riskMiniCard({
    required String testKey,
    required String label,
    required String value,
    required bool breached,
  }) {
    final color = breached ? AppColors.bearRed : AppColors.textPrimary;
    return Container(
      key: Key(testKey),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border.all(
          color: breached
              ? AppColors.bearRed.withValues(alpha: 0.6)
              : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _kv(String key, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(
                key,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: color ?? AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );

  static (String, Color, IconData) _statusVisuals(
      BitunixConnectionStatus status) {
    switch (status) {
      case BitunixConnectionStatus.disconnected:
        return (
          'Disconnected',
          AppColors.textMuted,
          Icons.cloud_off_outlined
        );
      case BitunixConnectionStatus.connecting:
        return (
          'Connecting…',
          AppColors.warningAmber,
          Icons.sync_outlined
        );
      case BitunixConnectionStatus.connected:
        return ('Connected', AppColors.bullGreen, Icons.cloud_done_outlined);
      case BitunixConnectionStatus.error:
        return ('Error', AppColors.bearRed, Icons.error_outline);
    }
  }

  static String _sideLabel(BitunixPositionSide side) {
    switch (side) {
      case BitunixPositionSide.long:
        return 'LONG';
      case BitunixPositionSide.short:
        return 'SHORT';
      case BitunixPositionSide.unknown:
        return '—';
    }
  }

  static String _formatNumber(double? value) {
    if (value == null) return '—';
    if (value == 0) return '0';
    final abs = value.abs();
    final fractionDigits = abs >= 100 ? 2 : (abs >= 1 ? 4 : 6);
    return value.toStringAsFixed(fractionDigits);
  }

  static String _formatTimestamp(DateTime ts) {
    final local = ts.toLocal();
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
  }
}
