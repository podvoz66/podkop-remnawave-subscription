# Публикация в GitHub

На локальном компьютере:

```sh
git init
git add .
git commit -m "Initial Podkop Remnawave subscription updater"
git branch -M main
git remote add origin git@github.com:YOUR_USERNAME/podkop-remnawave-subscription.git
git push -u origin main
```

Или через HTTPS:

```sh
git remote add origin https://github.com/YOUR_USERNAME/podkop-remnawave-subscription.git
git push -u origin main
```

Перед публикацией проверь, что в репозитории нет реального токена:

```sh
grep -R "SUB_URL='https://" .
grep -RniE 'vless://|ss://|trojan://|hysteria2://|hy2://' .
```

В репозитории должен быть только пример:

```text
examples/subscription.conf.example
```
