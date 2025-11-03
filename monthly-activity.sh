#!/bin/bash

# Load environment variables from .env file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    echo "Loading environment variables from .env file..."
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# Usage: ./monthly-activity.sh [github-username] [YYYY-MM]
# Example: ./monthly-activity.sh pk910 2025-10
# If github-username is not provided, GITHUB_USERNAME from .env will be used

github_user="${1:-$GITHUB_USERNAME}"
month="${2}"

if [ -z "$github_user" ] || [ -z "$month" ]; then
    echo "Usage: $0 [github-username] <YYYY-MM>"
    echo "Example: $0 pk910 2025-10"
    echo ""
    echo "GitHub username can be provided as argument or set in .env as GITHUB_USERNAME"
    exit 1
fi

# Check required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN is not set"
    echo "Please set it in .env file or export it as an environment variable"
    exit 1
fi

if [ -z "$OPENROUTER_TOKEN" ]; then
    echo "Error: OPENROUTER_TOKEN is not set"
    echo "Please set it in .env file or export it as an environment variable"
    exit 1
fi

# Setup temporary directory
TMP_DIR="$SCRIPT_DIR/.tmp"
mkdir -p "$TMP_DIR"

# Clear previous temporary files
rm -f "$TMP_DIR"/*

# Parse year and month
IFS='-' read -r year month_num <<< "$month"

# Calculate date range
start_date="${year}-${month_num}-01T00:00:00Z"
# Calculate last day of month
if [ "$month_num" == "12" ]; then
    next_month="01"
    next_year=$((year + 1))
else
    next_month=$(printf "%02d" $((10#$month_num + 1)))
    next_year=$year
fi
end_date="${next_year}-${next_month}-01T00:00:00Z"

echo "Fetching GitHub activity for @${github_user} from ${start_date} to ${end_date}..."

# Use GitHub Search API to find activity by date range
# Format dates for search (YYYY-MM-DD)
search_start_date="${year}-${month_num}-01"
# Calculate last day of month for search
if [ "$month_num" == "02" ]; then
    # Check for leap year
    if [ $((year % 4)) -eq 0 ] && { [ $((year % 100)) -ne 0 ] || [ $((year % 400)) -eq 0 ]; }; then
        search_end_date="${year}-${month_num}-29"
    else
        search_end_date="${year}-${month_num}-28"
    fi
elif [[ "$month_num" =~ ^(04|06|09|11)$ ]]; then
    search_end_date="${year}-${month_num}-30"
else
    search_end_date="${year}-${month_num}-31"
fi

activity_summary=""

echo "Fetching commits..."
# Fetch commits
commits_data=""
page=1
while [ $page -le 10 ]; do
    commits_response=$(curl -s -H "Authorization: bearer $GITHUB_TOKEN" \
        "https://api.github.com/search/commits?q=author:${github_user}+author-date:${search_start_date}..${search_end_date}&sort=author-date&order=desc&per_page=100&page=${page}" \
        -H "Accept: application/vnd.github.cloak-preview")

    commits_count=$(echo "$commits_response" | jq '.items | length // 0')
    if [ "$commits_count" -eq 0 ]; then
        break
    fi

    commits_data="${commits_data}$(echo "$commits_response" | jq -c '.items[]')"$'\n'
    page=$((page + 1))

    # Check if we got all results
    total_count=$(echo "$commits_response" | jq '.total_count // 0')
    if [ $((page * 100)) -gt "$total_count" ]; then
        break
    fi
done

echo "Fetching pull requests..."
# Fetch PRs
prs_data=""
page=1
while [ $page -le 10 ]; do
    prs_response=$(curl -s -H "Authorization: bearer $GITHUB_TOKEN" \
        "https://api.github.com/search/issues?q=author:${github_user}+type:pr+created:${search_start_date}..${search_end_date}&sort=created&order=desc&per_page=100&page=${page}")

    prs_count=$(echo "$prs_response" | jq '.items | length // 0')
    if [ "$prs_count" -eq 0 ]; then
        break
    fi

    prs_data="${prs_data}$(echo "$prs_response" | jq -c '.items[]')"$'\n'
    page=$((page + 1))

    total_count=$(echo "$prs_response" | jq '.total_count // 0')
    if [ $((page * 100)) -gt "$total_count" ]; then
        break
    fi
done

echo "Fetching issues..."
# Fetch Issues
issues_data=""
page=1
while [ $page -le 10 ]; do
    issues_response=$(curl -s -H "Authorization: bearer $GITHUB_TOKEN" \
        "https://api.github.com/search/issues?q=author:${github_user}+type:issue+created:${search_start_date}..${search_end_date}&sort=created&order=desc&per_page=100&page=${page}")

    issues_count=$(echo "$issues_response" | jq '.items | length // 0')
    if [ "$issues_count" -eq 0 ]; then
        break
    fi

    issues_data="${issues_data}$(echo "$issues_response" | jq -c '.items[]')"$'\n'
    page=$((page + 1))

    total_count=$(echo "$issues_response" | jq '.total_count // 0')
    if [ $((page * 100)) -gt "$total_count" ]; then
        break
    fi
done

echo "Processing activity data..."

# Save raw data
echo "$commits_data" > "$TMP_DIR/commits-raw.jsonl"
echo "$prs_data" > "$TMP_DIR/prs-raw.jsonl"
echo "$issues_data" > "$TMP_DIR/issues-raw.jsonl"

# Group commits by repository
if [ -n "$commits_data" ]; then
    activity_summary="${activity_summary}=== COMMITS ===\n\n"

    repos=$(echo "$commits_data" | jq -r '.repository.full_name' | sort -u)
    for repo in $repos; do
        repo_commits=$(echo "$commits_data" | jq -r --arg repo "$repo" 'select(.repository.full_name == $repo) | "- \(.commit.message | split("\n")[0])"')
        commit_count=$(echo "$repo_commits" | wc -l)

        activity_summary="${activity_summary}Repository: ${repo} (${commit_count} commits)\n${repo_commits}\n\n"
    done
fi

# Group PRs by repository
if [ -n "$prs_data" ]; then
    activity_summary="${activity_summary}=== PULL REQUESTS ===\n\n"

    pr_list=$(echo "$prs_data" | jq -r '"Repository: \(.repository_url | split("/")[-2:] | join("/"))\nPR #\(.number): \(.title)\nState: \(.state)\nURL: \(.html_url)\n"')
    activity_summary="${activity_summary}${pr_list}\n"
fi

# Group Issues by repository
if [ -n "$issues_data" ]; then
    activity_summary="${activity_summary}=== ISSUES ===\n\n"

    issue_list=$(echo "$issues_data" | jq -r '"Repository: \(.repository_url | split("/")[-2:] | join("/"))\nIssue #\(.number): \(.title)\nState: \(.state)\nURL: \(.html_url)\n"')
    activity_summary="${activity_summary}${issue_list}\n"
fi

if [ -z "$commits_data" ] && [ -z "$prs_data" ] && [ -z "$issues_data" ]; then
    echo "No activity found for the specified month."
    exit 1
fi

# Save activity summary for debugging
echo -e "$activity_summary" > "$TMP_DIR/activity-summary.txt"

echo "Generating AI summary..."

# Sanitize the activity summary by escaping backticks
activity_safe="${activity_summary//\`/\\\`}"

# Read example summaries for context
mkdir -p ./summaries
example_summaries=""
if [ -d ./summaries ]; then
    for summary_file in ./summaries/*.txt; do
        if [ -f "$summary_file" ]; then
            example_summaries="${example_summaries}

Example from $(basename "$summary_file"):
$(cat "$summary_file" | head -n 100)

---
"
        fi
    done
fi

conv=$(cat <<EOF
You are a helpful assistant that generates monthly work activity summaries for a software engineer.
You will be given GitHub activity data including commits, pull requests, and issues for various repositories.

GitHub Activity Data:
$activity_safe

Based on the activity above, generate a concise monthly work summary in the following format:

Format Guidelines:
- Group activities by repository/project name (use short name, not full path)
- Use bullet points with concise descriptions of what was done
- Focus on meaningful work: features added, bugs fixed, improvements made
- Use sub-bullets with arrows (→) for additional context or explanations (only if necessary)
- Keep descriptions concise and action-oriented
- Include a "side-quests:" section at the end for miscellaneous or smaller contributions
- Use lowercase for project names
- Do NOT include commit hashes, PR numbers, or technical jargon unless necessary
- Summarize and group similar commits/PRs together
- Focus on the "what" and "why", not the "how"

Example format:
project-name:
* added new feature for X
* fixed issue with Y
  → explanation or additional context
* improved Z performance

another-project:
* implemented A
* refactored B to support C

side-quests:
* miscellaneous contribution to project D
* minor fix in project E

Here are some real examples for reference:
$example_summaries

Do NOT respond with suggestions or meta-commentary! The response will be saved directly to a file.
Do NOT include markdown code blocks or formatting.
Generate ONLY the summary content in the exact format shown above.
Keep it short and precise. Do not include technical details or explanations.
Do not include commit hashes, PR numbers, or technical jargon unless necessary.
Avoid repeating previously recorded activities or generic updates (combine them if there are a lot of similar activities).
All repositories that live outside the ethereum/ or wthpandaops/ organization should be treated as side quests.
EOF
)

conv_json=$(echo "$conv" | jq -R -s '{"model": "'"${OPENROUTER_MODEL:-anthropic/claude-3.5-sonnet}"'", "messages": [{"role": "user", "content": .}]}')
conv_response=$(curl -s -X POST \
    -H "Authorization: Bearer $OPENROUTER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$conv_json" \
    https://openrouter.ai/api/v1/chat/completions)

# Save full response for debugging
echo "$conv_response" > "$TMP_DIR/ai-response.json"

# Extract the AI-generated summary
conv_response_text=$(echo "$conv_response" | jq -r '.choices[0].message.content')

if [ -z "$conv_response_text" ] || [ "$conv_response_text" == "null" ]; then
    echo "Error: Failed to generate AI summary"
    echo "Response: $conv_response"
    exit 1
fi

# Output the summary
output_file="./summaries/${month}.txt"
echo "$conv_response_text" > "$output_file"

echo ""
echo "Summary generated successfully!"
echo "Output file: $output_file"
echo ""
echo "Preview:"
echo "========================================"
cat "$output_file"
echo "========================================"

# Temporary files are in .tmp directory and will be cleaned up on next run
