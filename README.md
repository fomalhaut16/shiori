# shiori

読書の進み具合を Slack で記録し、止まっている本や積読を知らせる個人用の bot です。
常時起動している Windows の PC で動かします。サーバーや公開 URL は要りません。

## 使い方

### 記録する

Slack で shiori を開き、「ホーム」タブを見ます。読書中の本が、読んだ場所の地図（▰▱）と一緒に並びます。

本の「ページを記録」を押し、どこまで読んだかを数字で入れます。
飛ばして読んだときは「どこから」も入れると、その範囲だけを記録します。
進み具合は読んだページの合計で数え、全ページを読むと読了になります。

DM に数字を送っても記録できます。

| 送る内容 | 意味 |
| --- | --- |
| `128` | 128 ページまで読んだ（前回の続きから） |
| `+20` | 前回の続きから 20 ページ読んだ |
| `120-144 160-188` | この範囲を読んだ |

DM で記録すると、読書中の本が 1 冊ならその本に入ります。
2 冊以上あるときは、どの本かを選ぶボタンが返ってきます。
`#3 128` のように本の番号（ホームタブの書名の横）を付けると、その本に入ります。

どの記録にも「取り消す」ボタンが付きます。

### 本を追加する・状態を変える

ホームタブの「本を追加」を押し、書名と総ページ数を入れると、積読一覧に入ります。
ISBN を入れると、書名とページ数を調べて埋めます。
DM に `追加 書名 総ページ数` と送っても追加できます。2 行目から 1 行 1 冊で書けば、まとめて追加できます。

積読の本は「読み始める」で読書中になります。
中断、読了、書名と総ページの修正、削除は、ホームタブの各本の「︙」からできます。
DM で `?` と送ると、文字で操作するときの一覧が出ます。

### 読み終えた本を振り返る

読了すると、返信に「ひとこと感想を書く」ボタンが付きます。
ホームタブの「今年読んだ本」か DM の `読了一覧` で、読了日、かかった日数、ひとことの一覧が出ます。
`読了一覧 2025` のように年も指定できます。

## 定期通知

既定ではすべてオフです。`.env` で `on` にしたものだけが届きます。

- `WEEKLY_REPORT`：毎週日曜 21 時に、1 週間に読んだページ数、読書中の本の進み具合、積読の数
- `DAILY_NUDGE`：毎日 21 時に、3 日ページが進んでいない本。読書中の本がなければ、古い積読から 3 冊。何もなければ届きません
- `YEAR_REPORT`：12 月 31 日 21 時に、その年に読んだ本の一覧

時刻、曜日、日数も `.env` で変えられます。

## セットアップ

Ruby 3.2 以上と、Slack のワークスペースにアプリを追加できる権限が要ります。

1. <https://api.slack.com/apps> で「Create New App」→「From an app manifest」を選び、`slack-manifest.yml` の中身を貼り付けます。
2. 「Basic Information」→「App-Level Tokens」で、スコープ `connections:write` のトークン（`xapp-`）を作ります。
3. 「Install App」でワークスペースに入れ、「Bot User OAuth Token」（`xoxb-`）を控えます。
4. `.env.example` を `.env` にコピーし、2 つのトークンと自分の Slack メンバー ID（プロフィールの「︙」→「メンバー ID をコピー」）を書きます。
5. ライブラリを入れて、設定を確かめます。

   ```powershell
   bundle config set --local path vendor/bundle
   bundle install
   ruby bin/shiori check
   ```

6. 管理者の PowerShell で `scripts\install-task.ps1` を実行すると、PC の起動時に自動で動くようになります。試しに動かすだけなら `ruby bin/shiori` です。

### WSL で動かす

Windows の Smart App Control がオンだと、Windows に入れた Ruby はブロックされて動きません。その場合は WSL（Ubuntu 24.04）の中で動かします。

1. このリポジトリを WSL の `~/shiori` に置き、上の手順 4 と同じように `.env` を書きます。
2. Ruby とライブラリを入れて、設定を確かめます。

   ```bash
   sudo apt install ruby-full
   bundle3.2 config set --local path vendor/bundle
   bundle3.2 install
   bundle3.2 exec ruby bin/shiori check
   ```

3. systemd のサービスとして登録します。

   ```bash
   mkdir -p ~/.config/systemd/user
   cp scripts/shiori.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now shiori
   sudo loginctl enable-linger $USER
   ```

4. 管理者の PowerShell で `scripts\install-wsl-task.ps1` を実行します。Windows にログオンすると WSL が起動し、動き続けるようになります。PC を再起動したあとは、ログオンするまで動きません。

## 運用

| やりたいこと | 方法 |
| --- | --- |
| ログを見る | `Get-Content data\shiori.log -Wait -Tail 50` |
| 止める・動かす | `Stop-ScheduledTask shiori` / `Start-ScheduledTask shiori` |
| 自動起動をやめる | 管理者の PowerShell で `scripts\install-task.ps1 -Uninstall` |
| バックアップから戻す | タスクを止め、`data\backups\shiori-<日付>.db` を `data\shiori.db` に上書きする |

WSL で動かしているときは、止める・動かすのは `systemctl --user stop shiori` / `systemctl --user start shiori`、ログは `tail -f ~/shiori/data/shiori.log` です。

記録は `data\shiori.db`（SQLite）にあり、毎日 21 時にバックアップを作って 30 日分を残します。
PC が止まっている間に送った DM は、次に起動したときに履歴から読んで処理します。

## 開発

```powershell
bundle exec rake test
```

コードは `lib/shiori/` にあります。テーブルを変えるときは、`db/migrations/` に番号の続く `.sql` を追加します。
