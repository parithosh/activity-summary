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
# If github-usernames is not provided, GITHUB_USERNAME from .env will be used
# Multiple users can be specified as a comma-separated list
#
# Environment variables (.env file):
#   GITHUB_TOKEN        - Required: GitHub API token
#   OPENROUTER_TOKEN    - Required: OpenRouter API token
#   GITHUB_USERNAME     - Optional: Default GitHub username(s)
#   OPENROUTER_MODELS   - Optional: Comma-separated list of models (default: anthropic/claude-3.5-sonnet)
#                         Single model: "anthropic/claude-3.5-sonnet"
#                         Multiple models: "anthropic/claude-3.5-sonnet,openai/gpt-4,google/gemini-pro"

github_users_input="${1:-$GITHUB_USERNAME}"
month="${2}"

if [ -z "$github_users_input" ] || [ -z "$month" ]; then
    echo "Usage: $0 [github-usernames] <YYYY-MM>"
    echo "Example: $0 pk910 2025-10"
    echo "Example: $0 \"pk910,user2,user3\" 2025-10"
    echo ""
    echo "GitHub username(s) can be provided as argument or set in .env as GITHUB_USERNAME"
    echo "Multiple users can be specified as a comma-separated list"
    echo ""
    echo "Set OPENROUTER_MODELS in .env (comma-separated for comparison):"
    echo "  OPENROUTER_MODELS=\"anthropic/claude-3.5-sonnet,openai/gpt-4,google/gemini-pro\""
    exit 1
fi

# Parse comma-separated list of users into an array
IFS=',' read -ra github_users <<< "$github_users_input"

echo "Processing ${#github_users[@]} user(s): ${github_users[*]}"

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

echo "Fetching GitHub activity from ${start_date} to ${end_date}..."

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

# Initialize combined data variables
all_commits_data=""
all_prs_data=""
all_issues_data=""

# Fetch data for each user
for github_user in "${github_users[@]}"; do
    # Trim whitespace from username
    github_user=$(echo "$github_user" | xargs)

    echo ""
    echo "=== Fetching data for @${github_user} ==="

    echo "Fetching commits for @${github_user}..."
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

    echo "Fetching pull requests for @${github_user}..."
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

    echo "Fetching issues for @${github_user}..."
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

    # Append user's data to combined data
    all_commits_data="${all_commits_data}${commits_data}"
    all_prs_data="${all_prs_data}${prs_data}"
    all_issues_data="${all_issues_data}${issues_data}"
done

# Use combined data for processing
commits_data="$all_commits_data"
prs_data="$all_prs_data"
issues_data="$all_issues_data"

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

# Build user context for AI prompt
if [ ${#github_users[@]} -eq 1 ]; then
    user_context="a software engineer (${github_users[0]})"
else
    user_context="a team of ${#github_users[@]} software engineers ($(IFS=', '; echo "${github_users[*]}"))"
fi

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

# Parse models list (comma-separated, defaults to claude-3.5-sonnet)
IFS=',' read -ra models_list <<< "${OPENROUTER_MODELS:-anthropic/claude-3.5-sonnet}"

echo "Using ${#models_list[@]} model(s): ${models_list[*]}"
echo ""

# Array to store results for each model
declare -A model_outputs
declare -a successful_models

# Loop through each model
for model in "${models_list[@]}"; do
    # Trim whitespace from model name
    model=$(echo "$model" | xargs)

    echo "Generating summary with model: $model..."

    conv_json=$(echo "$conv" | jq -R -s --arg model "$model" '{"model": $model, "messages": [{"role": "user", "content": .}]}')
    conv_response=$(curl -s -X POST \
        -H "Authorization: Bearer $OPENROUTER_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$conv_json" \
        https://openrouter.ai/api/v1/chat/completions)

    # Save full response for debugging (use model name in filename)
    model_safe_name=$(echo "$model" | tr '/' '_')
    echo "$conv_response" > "$TMP_DIR/ai-response-${model_safe_name}.json"

    # Extract the AI-generated summary
    conv_response_text=$(echo "$conv_response" | jq -r '.choices[0].message.content')

    if [ -z "$conv_response_text" ] || [ "$conv_response_text" == "null" ]; then
        echo "Warning: Failed to generate AI summary with model: $model"
        echo "Response: $conv_response"
        echo ""
    else
        # Store the output
        model_outputs["$model"]="$conv_response_text"
        successful_models+=("$model")

        # Save individual model output
        output_file="./summaries/${month}-${model_safe_name}.txt"
        echo "$conv_response_text" > "$output_file"
        echo "Saved: $output_file"
        echo ""
    fi
done

# Check if we got any successful responses
if [ ${#successful_models[@]} -eq 0 ]; then
    echo "Error: Failed to generate summary with any model"
    exit 1
fi

echo ""
echo "========================================"
echo "SUMMARY GENERATION COMPLETE"
echo "========================================"
echo ""
echo "Generated ${#successful_models[@]} summary/summaries from: ${successful_models[*]}"
echo ""

# If only one model, save as the default output
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
    # Multiple models - show all outputs for comparison
    echo "Multiple model outputs generated. Review each below:"
    echo ""

    for model in "${successful_models[@]}"; do
        model_safe_name=$(echo "$model" | tr '/' '_')
        output_file="./summaries/${month}-${model_safe_name}.txt"

        echo "========================================"
        echo "MODEL: $model"
        echo "FILE: $output_file"
        echo "========================================"
        echo "${model_outputs[$model]}"
        echo ""
    done

    echo "========================================"
    echo "FILES GENERATED:"
    echo "========================================"
    for model in "${successful_models[@]}"; do
        model_safe_name=$(echo "$model" | tr '/' '_')
        echo "  - ./summaries/${month}-${model_safe_name}.txt ($model)"
    done
    echo ""
    echo "To use a specific model's output as the final summary, run:"
    echo "  cp ./summaries/${month}-<model_name>.txt ./summaries/${month}.txt"
fi

# Temporary files are in .tmp directory and will be cleaned up on next run
