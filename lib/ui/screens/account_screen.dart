/// Account screen — Welle P4P Step-4.
///
/// Five vertically stacked cards backed by [BitunixConnectionProvider]:
///   * Credentials-Card: API-Key + Secret entry, Save & Connect, Clear.
///   * Connection-Status-Card: status indicator, Test Connection (refresh),
///     last sync timestamp, error banner.
///   * Balance-Card: available / margin / unrealized PnL, only when
///     connected and a balance is loaded.
///   * Positions-Card: DataTable of open positions, only when connected.
///   * Live-Trading-Card: a **permanently disabled** switch with a tooltip
///     that points at the pending Welle B4 Step-3 risk layer. A widget
///     test asserts the switch stays disabled regardless of connection
///     status — accidental enable would be the worst possible regression.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models/bitunix_models.dart';
import '../../features/exchange/bitunix_connection_provider.dart';
import '../../services/bitunix_auth.dart';
import '../themes/app_theme.dart';

const String _kLiveDisabledTooltip =
    'Live trading requires Welle B4 Step-3 risk layer '
    '(kill-switch, daily-loss cap). Currently disabled.';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  bool _obscureSecret = true;

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

  @override
  Widget build(BuildContext context) {
    return Consumer<BitunixConnectionProvider>(
      builder: (context, provider, _) {
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
                  _liveTradingCard(context, provider),
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
      BuildContext context, BitunixConnectionProvider provider) {
    // Hardcoded false — the provider's getter is `false` by contract and
    // the switch has `onChanged: null`. Both layers must agree before a
    // future wave can flip live mode on.
    const liveEnabled = false;
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
                Container(
                  key: const Key('account_step3_pending_pill'),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.warningAmber.withValues(alpha: 0.14),
                    border: Border.all(
                        color: AppColors.warningAmber.withValues(alpha: 0.6)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Step-3 pending',
                    style: TextStyle(
                      color: AppColors.warningAmber,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Tooltip(
              key: const Key('account_live_trading_tooltip'),
              message: _kLiveDisabledTooltip,
              child: SwitchListTile(
                key: const Key('account_live_trading_switch'),
                title: const Text('Enable live order routing'),
                subtitle: const Text(
                  'Disabled until the risk layer ships in Welle B4 Step-3.',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
                value: liveEnabled,
                // CRITICAL: onChanged stays `null` so the switch is
                // structurally non-interactable. A widget regression test
                // pins this contract — if anyone removes the `null` here,
                // the test must fail.
                onChanged: null,
              ),
            ),
            // Belt-and-braces: even if the provider getter ever flips
            // (it shouldn't), the switch is still hard-coded to `false`
            // via `liveEnabled`. Surface a status line so a developer
            // who fiddles can see the dependency.
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
