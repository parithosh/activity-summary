#!/usr/bin/env bash

# Load environment variables from .env file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    echo "Loading environment variables from .env file..."
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# Usage: ./monthly-activity.sh [github-usernames] [YYYY-MM]
# Example: ./monthly-activity.sh pk910 2025-10
# Example: ./monthly-activity.sh "pk910,user2,user3" 2025-10

github_users_input="${1:-$GITHUB_USERNAME}"
month="${2}"

if [ -z "$github_users_input" ] || [ -z "$month" ]; then
    echo "Usage: $0 [github-usernames] <YYYY-MM>"
    echo "Example: $0 pk910 2025-10"
    echo "Example: $0 \"pk910,user2,user3\" 2025-10"
    echo ""
    echo "GitHub username(s) can be provided as argument or set in .env as GITHUB_USERNAME"
    echo "Set OPENROUTER_MODELS in .env (comma-separated for comparison)"
    exit 1
fi

IFS=',' read -ra github_users <<< "$github_users_input"
echo "Processing ${#github_users[@]} user(s): ${github_users[*]}"

# Check required environment variables
for var in GITHUB_TOKEN OPENROUTER_TOKEN; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set. Please set it in .env or export it."
        exit 1
    fi
done

# Setup temporary directory
TMP_DIR="$SCRIPT_DIR/.tmp"
mkdir -p "$TMP_DIR"
rm -f "$TMP_DIR"/*

# Parse year and month, calculate date range
IFS='-' read -r year month_num <<< "$month"
search_start_date="${year}-${month_num}-01"
# Calculate last day of month using date command
search_end_date=$(date -j -v1d -v+"$((10#$month_num))"m -v-1d -f "%Y-%m-%d" "${year}-01-01" "+%Y-%m-%d" 2>/dev/null || \
                  date -d "${year}-${month_num}-01 +1 month -1 day" "+%Y-%m-%d" 2>/dev/null || \
                  echo "${year}-${month_num}-28")

echo "Fetching GitHub activity from ${search_start_date} to ${search_end_date}..."

# Function to fetch paginated GitHub search results
fetch_github_data() {
    local query="$1"
    local extra_header="${2:-}"
    local data=""
    local page=1

    while [ $page -le 10 ]; do
        local response
        if [ -n "$extra_header" ]; then
            response=$(curl -s -H "Authorization: bearer $GITHUB_TOKEN" -H "$extra_header" "$query&per_page=100&page=${page}")
        else
            response=$(curl -s -H "Authorization: bearer $GITHUB_TOKEN" "$query&per_page=100&page=${page}")
        fi

        local count=$(echo "$response" | jq '.items | length // 0')
        [ "$count" -eq 0 ] && break

        data="${data}$(echo "$response" | jq -c '.items[]')"$'\n'
        page=$((page + 1))

        local total=$(echo "$response" | jq '.total_count // 0')
        [ $((page * 100)) -gt "$total" ] && break
    done

    echo "$data"
}

# Fetch data for each user
commits_data=""
prs_data=""
issues_data=""

for github_user in "${github_users[@]}"; do
    github_user=$(echo "$github_user" | xargs)
    echo ""
    echo "=== Fetching data for @${github_user} ==="

    echo "Fetching commits..."
    commits_data+=$(fetch_github_data \
        "https://api.github.com/search/commits?q=author:${github_user}+author-date:${search_start_date}..${search_end_date}&sort=author-date&order=desc" \
        "Accept: application/vnd.github.cloak-preview")

    echo "Fetching pull requests..."
    prs_data+=$(fetch_github_data \
        "https://api.github.com/search/issues?q=author:${github_user}+type:pr+created:${search_start_date}..${search_end_date}&sort=created&order=desc")

    echo "Fetching issues..."
    issues_data+=$(fetch_github_data \
        "https://api.github.com/search/issues?q=author:${github_user}+type:issue+created:${search_start_date}..${search_end_date}&sort=created&order=desc")
done

echo "Processing activity data..."

# Save raw data
echo "$commits_data" > "$TMP_DIR/commits-raw.jsonl"
echo "$prs_data" > "$TMP_DIR/prs-raw.jsonl"
echo "$issues_data" > "$TMP_DIR/issues-raw.jsonl"

# Build activity summary
activity_summary=""

if [ -n "$commits_data" ]; then
    activity_summary+="=== COMMITS ===\n\n"
    repos=$(echo "$commits_data" | jq -r '.repository.full_name' | sort -u)
    for repo in $repos; do
        repo_commits=$(echo "$commits_data" | jq -r --arg repo "$repo" 'select(.repository.full_name == $repo) | "- \(.commit.message | split("\n")[0])"')
        activity_summary+="Repository: ${repo} ($(echo "$repo_commits" | wc -l | xargs) commits)\n${repo_commits}\n\n"
    done
fi

if [ -n "$prs_data" ]; then
    activity_summary+="=== PULL REQUESTS ===\n\n"
    activity_summary+=$(echo "$prs_data" | jq -r '"Repository: \(.repository_url | split("/")[-2:] | join("/"))\nPR #\(.number): \(.title)\nState: \(.state)\nURL: \(.html_url)\n"')
    activity_summary+="\n"
fi

if [ -n "$issues_data" ]; then
    activity_summary+="=== ISSUES ===\n\n"
    activity_summary+=$(echo "$issues_data" | jq -r '"Repository: \(.repository_url | split("/")[-2:] | join("/"))\nIssue #\(.number): \(.title)\nState: \(.state)\nURL: \(.html_url)\n"')
    activity_summary+="\n"
fi

if [ -z "$commits_data" ] && [ -z "$prs_data" ] && [ -z "$issues_data" ]; then
    echo "No activity found for the specified month."
    exit 1
fi

echo -e "$activity_summary" > "$TMP_DIR/activity-summary.txt"
echo "Generating AI summary..."

# Read example summaries for context
mkdir -p ./summaries
example_summaries=$(find ./summaries -name "*.txt" -exec sh -c 'echo "Example from $(basename "$1"):"; head -n 100 "$1"; echo "---"' _ {} \; 2>/dev/null)

# Build user context for AI prompt
if [ ${#github_users[@]} -eq 1 ]; then
    user_context="a software engineer (${github_users[0]})"
else
    user_context="a team of ${#github_users[@]} software engineers ($(IFS=', '; echo "${github_users[*]}"))"
fi

# Sanitize the activity summary by escaping backticks
activity_safe="${activity_summary//\`/\\\`}"

conv=$(cat <<EOF
You are a helpful assistant that generates monthly work activity summaries for ${user_context}.
You will be given GitHub activity data including commits, pull requests, and issues for various repositories.

GitHub Activity Data:
$activity_safe

Based on the activity above, generate a concise monthly summary answering these 5 questions:

1. What was your team focused on over the last month?
2. What is going well?
3. What is not going well?
4. What are your team's top 1-3 priorities for the next month?
5. Is there anything else you want to share?

CRITICAL Guidelines:
- This summary will be read by an audience of 100+ people - ONLY include important, high-level topics
- When in doubt, LEAVE INFORMATION OUT rather than including it
- Focus on significant achievements, major blockers, and strategic priorities
- Avoid technical jargon, commit details, PR numbers, or implementation specifics
- Each answer should be 2-4 bullet points maximum
- Be concise and impactful - every sentence should matter
- For question 3 (not going well), infer from the activity patterns (e.g., many bug fixes might indicate stability issues, stalled PRs might indicate blockers)
- For question 4 (priorities), infer logical next steps based on the work completed
- Skip trivial contributions, minor fixes, and routine maintenance unless they represent a significant pattern

Example format:
1. What was your team focused on over the last month?
* Shipped major feature X that enables users to do Y
* Improved infrastructure reliability for the Z system

2. What is going well?
* Successfully launched X with positive initial feedback
* Team velocity improved after resolving technical debt

3. What is not going well?
* Ongoing stability issues in component Y requiring continued attention
* Resource constraints delaying priority work on Z

4. What are your team's top 1-3 priorities for the next month?
* Complete rollout of feature X to all users
* Address stability issues in Y

5. Is there anything else you want to share?
* Collaborating with team Z on upcoming initiative

Here are some real examples for reference:
$example_summaries

Do NOT respond with suggestions or meta-commentary! The response will be saved directly to a file.
Do NOT include markdown code blocks or formatting.
Generate ONLY the summary content in the exact format shown above.
Keep it executive-level - focus on impact, not activity.
EOF
)

# Helper to sanitize model name for filenames
safe_name() { echo "$1" | tr '/' '_'; }

# Parse models list
IFS=',' read -ra models_list <<< "${OPENROUTER_MODELS:-anthropic/claude-3.5-sonnet}"
echo "Using ${#models_list[@]} model(s): ${models_list[*]}"

declare -A model_outputs
declare -a successful_models

for model in "${models_list[@]}"; do
    model=$(echo "$model" | xargs)
    echo "Generating summary with model: $model..."

    conv_json=$(echo "$conv" | jq -R -s --arg model "$model" '{"model": $model, "messages": [{"role": "user", "content": .}]}')
    conv_response=$(curl -s -X POST \
        -H "Authorization: Bearer $OPENROUTER_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$conv_json" \
        https://openrouter.ai/api/v1/chat/completions)

    echo "$conv_response" > "$TMP_DIR/ai-response-$(safe_name "$model").json"
    conv_response_text=$(echo "$conv_response" | jq -r '.choices[0].message.content')

    if [ -z "$conv_response_text" ] || [ "$conv_response_text" == "null" ]; then
        echo "Warning: Failed to generate AI summary with model: $model"
        echo "Response: $conv_response"
    else
        model_outputs["$model"]="$conv_response_text"
        successful_models+=("$model")
        output_file="./summaries/${month}-$(safe_name "$model").txt"
        echo "$conv_response_text" > "$output_file"
        echo "Saved: $output_file"
    fi
    echo ""
done

if [ ${#successful_models[@]} -eq 0 ]; then
    echo "Error: Failed to generate summary with any model"
    exit 1
fi

echo "========================================"
echo "SUMMARY GENERATION COMPLETE"
echo "========================================"
echo "Generated ${#successful_models[@]} summary/summaries from: ${successful_models[*]}"
echo ""

if [ ${#successful_models[@]} -eq 1 ]; then
    output_file="./summaries/${month}.txt"
    echo "${model_outputs[${successful_models[0]}]}" > "$output_file"
    echo "Output file: $output_file"
    echo ""
    echo "Preview:"
    echo "========================================"
    cat "$output_file"
    echo "========================================"
else
    echo "Multiple model outputs generated:"
    for model in "${successful_models[@]}"; do
        echo "  - ./summaries/${month}-$(safe_name "$model").txt ($model)"
    done
    echo ""
    echo "To use a specific output as final: cp ./summaries/${month}-<model>.txt ./summaries/${month}.txt"
fi
