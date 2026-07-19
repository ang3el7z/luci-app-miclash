import * as errors from 'miclash.errors';

const STRINGS = {
	en: {
		back: 'Back', cancel: 'Cancel', confirm: 'Confirm', refresh: 'Refresh',
		main_title: 'MiClash control panel', status: 'Status', management: 'Management',
		subscription: 'Subscription', updates: 'Updates', guard: 'Guard', memory: 'Memory',
		logs: 'Logs', diagnostics: 'Diagnostics', reboot_router: 'Reboot router',
		start_service: 'Start', stop_service: 'Stop', reload_service: 'Reload',
		restart_service: 'Restart', update_configuration: 'Update configuration',
		replace_url: 'Replace URL', check_updates: 'Check updates',
		subscription_input_body: 'Send the new subscription URL in your next message. This request expires in 10 minutes.',
		update_miclash: 'Update MiClash', update_mihomo: 'Update Mihomo',
		enable_guard: 'Enable Guard', disable_guard: 'Disable Guard',
		run_route_check: 'Run route check',
		main_body: 'MiClash {{miclash_version}} — {{miclash_state}}\nMihomo {{mihomo_version}} — {{mihomo_state}}\nProxy mode: {{proxy_mode}}\nGuard: {{guard_state}}\nInternet: {{internet_state}}',
		status_body: 'Status\n\nMiClash: {{miclash_state}}\nMihomo: {{mihomo_state}}\nDNS: {{dns_state}}\nFirewall: {{firewall_state}}\nRouting: {{routing_state}}\nConfiguration updates: {{config_update_state}}\nMiClash updates: {{miclash_update_state}}',
		management_body: 'Management\n\nService: {{service_state}}',
		subscription_body: 'Subscription\n\nCurrent URL:\n{{subscription_url}}\n\nLast update: {{last_update}}\nResult: {{last_result}}',
		updates_body: 'Updates\n\nMiClash: {{miclash_installed}} → {{miclash_available}}\nMihomo: {{mihomo_installed}} → {{mihomo_available}}',
		guard_body: 'Guard\n\nConfigured: {{guard_state}}\nObserved: {{guard_observed}}',
		memory_body: 'Memory\n\nMihomo memory (RSS): {{memory_rss}}\nBaseline: {{memory_baseline}}\nStatus: {{memory_state}}\nLast action: {{last_memory_action}}',
		logs_body: 'Logs\n\n{{logs}}', diagnostics_body: 'Diagnostics\n\n{{diagnostics}}',
		confirm_stop_body: 'Stop MiClash? Devices protected by Guard may lose Internet access.',
		confirm_guard_off_body: 'Disable Guard? Devices may access the Internet directly if MiClash fails.',
		confirm_reboot_body: 'Reboot the router now? Network access will be temporarily interrupted.',
		confirm_update_miclash_body: 'Install the available MiClash update now?',
		confirm_update_mihomo_body: 'Install the available Mihomo update now?',
		operation_accepted: 'Operation {{operation}} accepted', unavailable: 'Unavailable',
		operation_result: '{{operation}}: {{state}}', operation_success: 'Completed',
		operation_failure: 'Failed', operation_interrupted: 'Interrupted',
		enabled: 'Enabled', disabled: 'Disabled', ready: 'Ready', running: 'Running',
		stopped: 'Stopped', unknown: 'Unknown', not_configured: 'Not configured',
		command_start: 'Open the MiClash control panel', command_menu: 'Open the control panel',
		command_status: 'Show MiClash status', command_health: 'Check required components',
		command_memory: 'Show Mihomo memory status', command_diagnostics: 'Show diagnostics summary',
		command_logs: 'Show recent MiClash logs', command_help: 'Show available commands',
		command_start_service: 'Start MiClash', command_stop_service: 'Stop MiClash',
		command_reload_service: 'Reload MiClash', command_restart_service: 'Restart MiClash',
		command_reboot_router: 'Reboot the router', command_subscription: 'Replace subscription URL',
		command_update_subscription: 'Update configuration from subscription',
		command_update_miclash: 'Update MiClash', command_update_mihomo: 'Update Mihomo',
		command_guard_on: 'Enable Guard', command_guard_off: 'Disable Guard'
	},
	ru: {
		back: 'Назад', cancel: 'Отмена', confirm: 'Подтвердить', refresh: 'Обновить',
		main_title: 'Панель управления MiClash', status: 'Состояние', management: 'Управление',
		subscription: 'Подписка', updates: 'Обновления', guard: 'Защита', memory: 'Память',
		logs: 'Логи', diagnostics: 'Диагностика', reboot_router: 'Перезагрузить роутер',
		start_service: 'Запустить', stop_service: 'Остановить', reload_service: 'Перезагрузить конфиг',
		restart_service: 'Перезапустить', update_configuration: 'Обновить конфигурацию',
		replace_url: 'Заменить ссылку', check_updates: 'Проверить обновления',
		subscription_input_body: 'Отправьте новую ссылку подписки следующим сообщением. Запрос действует 10 минут.',
		update_miclash: 'Обновить MiClash', update_mihomo: 'Обновить Mihomo',
		enable_guard: 'Включить защиту', disable_guard: 'Отключить защиту',
		run_route_check: 'Проверить маршрутизацию',
		main_body: 'Панель управления MiClash\n\nMiClash {{miclash_version}} — {{miclash_state}}\nMihomo {{mihomo_version}} — {{mihomo_state}}\nРежим прокси: {{proxy_mode}}\nЗащита: {{guard_state}}\nИнтернет: {{internet_state}}',
		status_body: 'Состояние\n\nMiClash: {{miclash_state}}\nMihomo: {{mihomo_state}}\nDNS: {{dns_state}}\nМежсетевой экран: {{firewall_state}}\nМаршрутизация: {{routing_state}}\nОбновление конфигурации: {{config_update_state}}\nОбновление MiClash: {{miclash_update_state}}',
		management_body: 'Управление\n\nСлужба: {{service_state}}',
		subscription_body: 'Подписка\n\nТекущая ссылка:\n{{subscription_url}}\n\nПоследнее обновление: {{last_update}}\nРезультат: {{last_result}}',
		updates_body: 'Обновления\n\nMiClash: {{miclash_installed}} → {{miclash_available}}\nMihomo: {{mihomo_installed}} → {{mihomo_available}}',
		guard_body: 'Защита\n\nНастройка: {{guard_state}}\nФактическое состояние: {{guard_observed}}',
		memory_body: 'Память\n\nПамять Mihomo (RSS): {{memory_rss}}\nБазовый уровень: {{memory_baseline}}\nСтатус: {{memory_state}}\nПоследнее действие: {{last_memory_action}}',
		logs_body: 'Логи\n\n{{logs}}', diagnostics_body: 'Диагностика\n\n{{diagnostics}}',
		confirm_stop_body: 'Остановить MiClash? Устройства под защитой могут потерять доступ в Интернет.',
		confirm_guard_off_body: 'Отключить защиту? При сбое MiClash устройства смогут выйти в Интернет напрямую.',
		confirm_reboot_body: 'Перезагрузить роутер сейчас? Сеть будет временно недоступна.',
		confirm_update_miclash_body: 'Установить доступное обновление MiClash сейчас?',
		confirm_update_mihomo_body: 'Установить доступное обновление Mihomo сейчас?',
		operation_accepted: 'Операция {{operation}} принята', unavailable: 'Недоступно',
		operation_result: '{{operation}}: {{state}}', operation_success: 'Завершено',
		operation_failure: 'Ошибка', operation_interrupted: 'Прервано',
		enabled: 'Включено', disabled: 'Отключено', ready: 'Готово', running: 'Запущено',
		stopped: 'Остановлено', unknown: 'Неизвестно', not_configured: 'Не настроено',
		command_start: 'Открыть панель управления MiClash', command_menu: 'Открыть панель управления',
		command_status: 'Показать состояние MiClash', command_health: 'Проверить основные компоненты',
		command_memory: 'Показать состояние памяти Mihomo', command_diagnostics: 'Показать сводку диагностики',
		command_logs: 'Показать последние логи MiClash', command_help: 'Показать доступные команды',
		command_start_service: 'Запустить MiClash', command_stop_service: 'Остановить MiClash',
		command_reload_service: 'Перезагрузить конфиг MiClash', command_restart_service: 'Перезапустить MiClash',
		command_reboot_router: 'Перезагрузить роутер', command_subscription: 'Заменить ссылку подписки',
		command_update_subscription: 'Обновить конфигурацию из подписки',
		command_update_miclash: 'Обновить MiClash', command_update_mihomo: 'Обновить Mihomo',
		command_guard_on: 'Включить защиту', command_guard_off: 'Отключить защиту'
	},
	'zh-cn': {
		back: '返回', cancel: '取消', confirm: '确认', refresh: '刷新',
		main_title: 'MiClash 控制面板', status: '状态', management: '管理',
		subscription: '订阅', updates: '更新', guard: '保护', memory: '内存',
		logs: '日志', diagnostics: '诊断', reboot_router: '重启路由器',
		start_service: '启动', stop_service: '停止', reload_service: '重新加载',
		restart_service: '重启服务', update_configuration: '更新配置', replace_url: '更换链接',
		check_updates: '检查更新', update_miclash: '更新 MiClash', update_mihomo: '更新 Mihomo',
		subscription_input_body: '请在下一条消息中发送新的订阅链接。此请求将在 10 分钟后失效。',
		enable_guard: '启用保护', disable_guard: '停用保护', run_route_check: '检查路由',
		main_body: 'MiClash 控制面板\n\nMiClash {{miclash_version}} — {{miclash_state}}\nMihomo {{mihomo_version}} — {{mihomo_state}}\n代理模式：{{proxy_mode}}\n保护：{{guard_state}}\n网络：{{internet_state}}',
		status_body: '状态\n\nMiClash：{{miclash_state}}\nMihomo：{{mihomo_state}}\nDNS：{{dns_state}}\n防火墙：{{firewall_state}}\n路由：{{routing_state}}\n配置更新：{{config_update_state}}\nMiClash 更新：{{miclash_update_state}}',
		management_body: '管理\n\n服务：{{service_state}}',
		subscription_body: '订阅\n\n当前链接：\n{{subscription_url}}\n\n上次更新：{{last_update}}\n结果：{{last_result}}',
		updates_body: '更新\n\nMiClash：{{miclash_installed}} → {{miclash_available}}\nMihomo：{{mihomo_installed}} → {{mihomo_available}}',
		guard_body: '保护\n\n设置：{{guard_state}}\n实际状态：{{guard_observed}}',
		memory_body: '内存\n\nMihomo 内存 (RSS)：{{memory_rss}}\n基准：{{memory_baseline}}\n状态：{{memory_state}}\n上次操作：{{last_memory_action}}',
		logs_body: '日志\n\n{{logs}}', diagnostics_body: '诊断\n\n{{diagnostics}}',
		confirm_stop_body: '停止 MiClash？受保护的设备可能会失去网络连接。',
		confirm_guard_off_body: '停用保护？MiClash 故障时设备可能会直接访问网络。',
		confirm_reboot_body: '现在重启路由器？网络连接将暂时中断。',
		confirm_update_miclash_body: '现在安装可用的 MiClash 更新？',
		confirm_update_mihomo_body: '现在安装可用的 Mihomo 更新？',
		operation_accepted: '操作 {{operation}} 已接受', unavailable: '不可用',
		operation_result: '{{operation}}：{{state}}', operation_success: '已完成',
		operation_failure: '失败', operation_interrupted: '已中断',
		enabled: '已启用', disabled: '已停用', ready: '就绪', running: '运行中',
		stopped: '已停止', unknown: '未知', not_configured: '未配置',
		command_start: '打开 MiClash 控制面板', command_menu: '打开控制面板',
		command_status: '显示 MiClash 状态', command_health: '检查主要组件',
		command_memory: '显示 Mihomo 内存状态', command_diagnostics: '显示诊断摘要',
		command_logs: '显示最近的 MiClash 日志', command_help: '显示可用命令',
		command_start_service: '启动 MiClash', command_stop_service: '停止 MiClash',
		command_reload_service: '重新加载 MiClash', command_restart_service: '重启 MiClash',
		command_reboot_router: '重启路由器', command_subscription: '更换订阅链接',
		command_update_subscription: '从订阅更新配置', command_update_miclash: '更新 MiClash',
		command_update_mihomo: '更新 Mihomo', command_guard_on: '启用保护',
		command_guard_off: '停用保护'
	}
};

function normalize(value) {
	if (type(value) != 'string') return 'en';
	value = lc(replace(value, /_/, '-'));
	if (match(value, /^ru($|-)/)) return 'ru';
	if (match(value, /^zh($|-)/)) return 'zh-cn';
	if (match(value, /^en($|-)/)) return 'en';
	return 'en';
};

export function locale(runtime) {
	try {
		let cursor = runtime?.uci?.cursor();
		if (type(cursor?.get) != 'function') return 'en';
		return normalize(cursor.get('luci', 'main', 'lang'));
	}
	catch (error) { return 'en'; }
};

export function telegram_language(value) {
	value = normalize(value);
	return value == 'zh-cn' ? 'zh' : (value == 'ru' ? 'ru' : '');
};

export function text(locale_name, key, values) {
	if (type(key) != 'string' || !match(key, /^[a-z0-9_]+$/))
		errors.fail('INVALID_ARGUMENT');
	let table = STRINGS[normalize(locale_name)], template = table[key] ?? STRINGS.en[key];
	if (type(template) != 'string') errors.fail('INVALID_ARGUMENT');
	values ??= {};
	if (type(values) != 'object' || type(values) == 'array') errors.fail('INVALID_ARGUMENT');
	for (let name, value in values) {
		if (!match(name, /^[a-z0-9_]+$/) || index(template, '{{' + name + '}}') < 0 ||
		    (type(value) != 'string' && type(value) != 'int' && type(value) != 'bool'))
			errors.fail('INVALID_ARGUMENT');
		template = join(sprintf('%s', value), split(template, '{{' + name + '}}'));
	}
	if (match(template, /\{\{[a-z0-9_]+\}\}/)) errors.fail('INVALID_ARGUMENT');
	return template;
};
