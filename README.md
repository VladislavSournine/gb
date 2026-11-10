# gb — Game Block

Скрипт для шкільних комп'ютерів на Windows 10/11, який блокує ігрові сайти, TikTok, Instagram і Twitch. Працює через системний файл `hosts`: заблокований сайт просто не відкривається в жодному браузері. Доступ до роутера не потрібен, достатньо один раз запустити скрипт на кожному комп'ютері.

## Швидкий запуск

1. Відкрий PowerShell **від адміністратора** (Win+X → «Термінал (адміністратор)»).
2. Встав команду:

   ```powershell
   irm is.gd/4N9GTq | iex
   ```

   Коротке посилання [is.gd/4N9GTq](https://is.gd/4N9GTq) веде на скрипт у цьому репозиторії. Якщо шкільна мережа блокує шортнери, використовуй повне посилання:

   ```powershell
   irm https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1 | iex
   ```

3. Зачекай 1–3 хвилини, доки з'явиться зелений рядок `Blocked ... host names`.
4. Перезапусти браузери.

Перевірка: `ping friv.com` має відповідати з `0.0.0.0`.

## Що робить скрипт

- Завантажує два списки й об'єднує їх:
  - [UT1 games](https://raw.githubusercontent.com/olbat/ut1-blacklists/master/blacklists/games/domains) — ~33 тис. ігрових доменів, список підтримує Тулузький університет;
  - [`custom-block.txt`](custom-block.txt) — власний список: TikTok, Instagram, Twitch, піддомени Roblox. Його можна редагувати прямо на GitHub, і зміни потраплять на комп'ютер під час наступного запуску скрипта.
- Додає до кожного домену `www.`-варіант і записує все в `hosts` як `0.0.0.0` між мітками `GAME-BLOCK BEGIN/END`. Решту файлу `hosts` не чіпає.
- Вимикає «безпечний DNS» (DNS-over-HTTPS) у Chrome, Edge і Firefox через політики, щоб браузери не обходили `hosts`.
- Скидає кеш DNS.

Скрипт можна запускати повторно: старий блок замінюється новим, дублікатів не буде. Якщо список не завантажився, `hosts` лишається без змін.

## Параметри

```powershell
$url = 'https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1'

# додати власні домени
& ([scriptblock]::Create((irm $url))) -Extra roblox.com,epicgames.com,steampowered.com

# зняти блокування
& ([scriptblock]::Create((irm $url))) -Remove

# без www-варіантів (hosts удвічі менший)
& ([scriptblock]::Create((irm $url))) -NoWww
```

| Параметр | Що робить |
|---|---|
| `-ListUrl` | свої списки замість стандартних (масив URL, plain text, один домен на рядок) |
| `-Extra` | додаткові домени |
| `-Remove` | прибрати блок і повернути налаштування DoH |
| `-NoWww` | не додавати `www.`-варіанти |
| `-SkipBrowserPolicy` | не змінювати політики браузерів |

## Автооновлення списку (необов'язково)

Створює задачу, яка щопонеділка о 8:00 запускає скрипт від імені SYSTEM:

```powershell
$cmd = "irm https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1 | iex"
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 8am
Register-ScheduledTask -TaskName 'GameBlock' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force
```

## Обмеження

- `hosts` не підтримує wildcard: піддомен, якого немає у списку, не заблокується. Такі піддомени додавай через `-Extra`.
- Якщо учень має права адміна, він може відредагувати `hosts`. Тому учнівські акаунти мають бути без адмін-прав.
- VPN і проксі-розширення обходять `hosts`.
- Оригінальний `hosts` зберігається один раз у `hosts.game-block.bak`.
