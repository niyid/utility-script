import os
import subprocess
from datetime import datetime
from github import Github

# ==== CONFIGURATION ====
GITHUB_TOKEN = os.environ.get('GITHUB_TOKEN') or subprocess.check_output(['gh', 'auth', 'token'], text=True).strip()
LOCAL_CLONE_DIR = './'
REFRESH_FILE = 'refresh.txt'
REPOS_TO_SKIP = [
    'moneroodoo',
    'apo',
    'ajo-android',
    'misq',
    'bitchat',
    'bitchat-android',
    'incubator-bisq-xmr-integration',
    'RandomX',
    'samourai-wallet-android',
    'monero',
    'wallet-android',
    'bisq2_android',
    'bitcoin-wallet',
    'haveno',
    'haveno-ts',
    'haveno-sample-app',
    'libunwind',
    'QR-Code-generator',
    'monero-cpp',
    'monero-gui',
    'monero-java'
    
]
CONTRIBUTORS_FILE = 'CONTRIBUTORS.md'
CONTRIBUTORS_START = '<!-- CONTRIBUTORS START -->'
CONTRIBUTORS_END = '<!-- CONTRIBUTORS END -->'
# ========================

def update_refresh_file(repo_path):
    """Create or update refresh.txt with the current timestamp."""
    file_path = os.path.join(repo_path, REFRESH_FILE)
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    content = f'Refreshed at {now}\n'
    with open(file_path, 'w') as f:
        f.write(content)
    return now

def get_contributors_markdown(repo):
    """Return a markdown table of contributors."""
    contributors = list(repo.get_contributors())
    lines = [CONTRIBUTORS_START]
    lines.append("| Avatar | Username |")
    lines.append("|--------|----------|")

    for user in contributors:
        avatar = f'<img src="{user.avatar_url}" width="32"/>'
        username = f"[{user.login}](https://github.com/{user.login})"
        lines.append(f"| {avatar} | {username} |")

    lines.append(CONTRIBUTORS_END)
    return "\n".join(lines) + "\n"

def update_contributors_md(repo_path, repo):
    """Create or update CONTRIBUTORS.md with contributors table."""
    file_path = os.path.join(repo_path, CONTRIBUTORS_FILE)
    new_block = get_contributors_markdown(repo)

    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            content = f.read()
        start = content.find(CONTRIBUTORS_START)
        end = content.find(CONTRIBUTORS_END)
        if start != -1 and end != -1:
            old_block = content[start:end + len(CONTRIBUTORS_END)]
            new_content = content.replace(old_block, new_block)
        else:
            new_content = content.strip() + "\n\n" + new_block
    else:
        new_content = new_block

    with open(file_path, 'w') as f:
        f.write(new_content)

    return True  # Always stage it

def run_git_commands(repo_path, now_str, has_contrib_changes):
    """Stage, commit, and push changes."""
    subprocess.run(['git', 'add', REFRESH_FILE], cwd=repo_path, check=True)
    if has_contrib_changes:
        subprocess.run(['git', 'add', CONTRIBUTORS_FILE], cwd=repo_path, check=True)

    commit_message = f'Added CONTRIBUTORS.md document and repository refreshed at {now_str}'
    subprocess.run(['git', 'commit', '-m', commit_message], cwd=repo_path, check=True)
    subprocess.run(['git', 'push'], cwd=repo_path, check=True)

def clone_or_pull(repo_url, repo_name):
    """Clone the repo if not already cloned, otherwise pull latest changes."""
    repo_path = os.path.join(LOCAL_CLONE_DIR, repo_name)
    if os.path.exists(repo_path):
        print(f'🔁 Pulling latest for {repo_name}...')
        subprocess.run(['git', 'pull'], cwd=repo_path, check=True)
    else:
        print(f'📥 Cloning {repo_name}...')
        subprocess.run(['git', 'clone', repo_url, repo_path], check=True)
    return repo_path

def main():
    os.makedirs(LOCAL_CLONE_DIR, exist_ok=True)
    g = Github(GITHUB_TOKEN)
    user = g.get_user()

    for repo in user.get_repos():
        if repo.name in REPOS_TO_SKIP:
            print(f'⏭️  Skipping {repo.full_name} (in skip list)')
            continue
        if repo.archived:
            print(f'📦 Skipping {repo.full_name} (archived)')
            continue
        try:
            print(f'🔄 Processing {repo.full_name}')
            repo_path = clone_or_pull(repo.clone_url, repo.name)
            now_str = update_refresh_file(repo_path)
            has_contrib_changes = update_contributors_md(repo_path, repo)
            run_git_commands(repo_path, now_str, has_contrib_changes)
            print(f'✅ Refreshed {repo.full_name}')
        except subprocess.CalledProcessError as e:
            print(f'❌ Git error with {repo.full_name}: {e}')
        except Exception as e:
            print(f'❌ Error with {repo.full_name}: {e}')

if __name__ == '__main__':
    main()

