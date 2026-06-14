import os, email, glob
#/home/vivragulina/.local/share/evolution/mail/local/.Sent/cur
maildir = os.path.expanduser("/home/vivragulina/.local/share/evolution/mail/local/.Sent/cur")
seen = {}

print(f"Привет мир!")

for path in glob.glob(maildir + "/*"):
    with open(path, "rb") as f:
        msg = email.message_from_binary_file(f)
    mid=msg.get("Message-ID")
    if mid:
        if mid in seen:
            print(f"Дубль: {path}")
            # os.remove(path)
        else:
            seen[mid] = path
