#!/usr/bin/env python3
"""
Log Analyzer - Analyze system and application logs
Provides pattern matching, error detection, and statistical analysis
"""

import re
import argparse
import gzip
from datetime import datetime, timedelta
from collections import defaultdict, Counter
from pathlib import Path
import json


class LogAnalyzer:
    def __init__(self):
        self.patterns = {
            'error': re.compile(r'\b(error|fail|exception|critical|fatal)\b', re.IGNORECASE),
            'warning': re.compile(r'\b(warn|warning|caution)\b', re.IGNORECASE),
            'ip': re.compile(r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b'),
            'timestamp_syslog': re.compile(r'^(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})'),
            'timestamp_apache': re.compile(r'\[(\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2}\s+[+-]\d{4})\]'),
            'timestamp_nginx': re.compile(r'(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})'),
            'http_status': re.compile(r'\s([1-5]\d{2})\s'),
            'ssh_login': re.compile(r'sshd.*Accepted.*for\s+(\w+)\s+from\s+([\d.]+)'),
            'ssh_failed': re.compile(r'sshd.*Failed.*for\s+(\w+)\s+from\s+([\d.]+)'),
            'sudo_usage': re.compile(r'sudo:\s+(\w+).*COMMAND=(.*)'),
        }
    
    def open_log_file(self, filepath):
        """Open log file, handling gzipped files automatically"""
        filepath = Path(filepath)
        if filepath.suffix == '.gz':
            return gzip.open(filepath, 'rt', encoding='utf-8', errors='ignore')
        else:
            return open(filepath, 'r', encoding='utf-8', errors='ignore')
    
    def parse_timestamp(self, line):
        """Extract timestamp from log line"""
        # Try syslog format
        match = self.patterns['timestamp_syslog'].search(line)
        if match:
            try:
                # Assume current year for syslog format
                timestamp_str = f"{datetime.now().year} {match.group(1)}"
                return datetime.strptime(timestamp_str, "%Y %b %d %H:%M:%S")
            except ValueError:
                pass
        
        # Try Apache format
        match = self.patterns['timestamp_apache'].search(line)
        if match:
            try:
                return datetime.strptime(match.group(1)[:20], "%d/%b/%Y:%H:%M:%S")
            except ValueError:
                pass
        
        # Try Nginx format
        match = self.patterns['timestamp_nginx'].search(line)
        if match:
            try:
                return datetime.strptime(match.group(1), "%Y/%m/%d %H:%M:%S")
            except ValueError:
                pass
        
        return None
    
    def analyze_errors_warnings(self, filepath, time_range=None):
        """Analyze errors and warnings in log file"""
        results = {
            'errors': [],
            'warnings': [],
            'error_count': 0,
            'warning_count': 0,
            'total_lines': 0
        }
        
        with self.open_log_file(filepath) as f:
            for line_num, line in enumerate(f, 1):
                results['total_lines'] += 1
                
                # Check time range if specified
                if time_range:
                    timestamp = self.parse_timestamp(line)
                    if timestamp and not (time_range[0] <= timestamp <= time_range[1]):
                        continue
                
                # Check for errors
                if self.patterns['error'].search(line):
                    results['errors'].append({
                        'line_number': line_num,
                        'content': line.strip(),
                        'timestamp': self.parse_timestamp(line)
                    })
                    results['error_count'] += 1
                
                # Check for warnings
                elif self.patterns['warning'].search(line):
                    results['warnings'].append({
                        'line_number': line_num,
                        'content': line.strip(),
                        'timestamp': self.parse_timestamp(line)
                    })
                    results['warning_count'] += 1
        
        return results
    
    def analyze_ip_addresses(self, filepath):
        """Analyze IP addresses in log file"""
        ip_counts = Counter()
        ip_first_seen = {}
        ip_last_seen = {}
        
        with self.open_log_file(filepath) as f:
            for line in f:
                timestamp = self.parse_timestamp(line)
                ips = self.patterns['ip'].findall(line)
                
                for ip in ips:
                    ip_counts[ip] += 1
                    if ip not in ip_first_seen:
                        ip_first_seen[ip] = timestamp
                    ip_last_seen[ip] = timestamp
        
        return {
            'ip_counts': ip_counts,
            'ip_first_seen': ip_first_seen,
            'ip_last_seen': ip_last_seen,
            'unique_ips': len(ip_counts),
            'total_ip_occurrences': sum(ip_counts.values())
        }
    
    def analyze_ssh_activity(self, filepath):
        """Analyze SSH login activities"""
        successful_logins = []
        failed_logins = []
        
        with self.open_log_file(filepath) as f:
            for line in f:
                timestamp = self.parse_timestamp(line)
                
                # Check successful SSH logins
                match = self.patterns['ssh_login'].search(line)
                if match:
                    successful_logins.append({
                        'user': match.group(1),
                        'ip': match.group(2),
                        'timestamp': timestamp,
                        'line': line.strip()
                    })
                
                # Check failed SSH attempts
                match = self.patterns['ssh_failed'].search(line)
                if match:
                    failed_logins.append({
                        'user': match.group(1),
                        'ip': match.group(2),
                        'timestamp': timestamp,
                        'line': line.strip()
                    })
        
        return {
            'successful_logins': successful_logins,
            'failed_logins': failed_logins,
            'successful_count': len(successful_logins),
            'failed_count': len(failed_logins)
        }
    
    def analyze_http_status_codes(self, filepath):
        """Analyze HTTP status codes in web server logs"""
        status_counts = Counter()
        
        with self.open_log_file(filepath) as f:
            for line in f:
                matches = self.patterns['http_status'].findall(line)
                for status in matches:
                    status_counts[status] += 1
        
        return {
            'status_counts': status_counts,
            'total_requests': sum(status_counts.values())
        }
    
    def search_pattern(self, filepath, pattern, context_lines=0, case_sensitive=True):
        """Search for custom pattern in log file"""
        flags = 0 if case_sensitive else re.IGNORECASE
        regex = re.compile(pattern, flags)
        results = []
        
        with self.open_log_file(filepath) as f:
            lines = f.readlines()
        
        for i, line in enumerate(lines):
            if regex.search(line):
                result = {
                    'line_number': i + 1,
                    'content': line.strip(),
                    'timestamp': self.parse_timestamp(line)
                }
                
                # Add context lines if requested
                if context_lines > 0:
                    start = max(0, i - context_lines)
                    end = min(len(lines), i + context_lines + 1)
                    result['context'] = [
                        f"{j+1}: {lines[j].strip()}" 
                        for j in range(start, end)
                    ]
                
                results.append(result)
        
        return results
    
    def generate_report(self, filepath, output_format='text'):
        """Generate comprehensive log analysis report"""
        print(f"Analyzing log file: {filepath}")
        print("=" * 60)
        
        # Error and warning analysis
        print("\n1. Errors and Warnings Analysis:")
        error_analysis = self.analyze_errors_warnings(filepath)
        print(f"   Total lines processed: {error_analysis['total_lines']}")
        print(f"   Errors found: {error_analysis['error_count']}")
        print(f"   Warnings found: {error_analysis['warning_count']}")
        
        if error_analysis['error_count'] > 0:
            print("\n   Recent errors:")
            for error in error_analysis['errors'][-5:]:  # Show last 5 errors
                print(f"     Line {error['line_number']}: {error['content'][:100]}...")
        
        # IP address analysis
        print("\n2. IP Address Analysis:")
        ip_analysis = self.analyze_ip_addresses(filepath)
        print(f"   Unique IP addresses: {ip_analysis['unique_ips']}")
        print(f"   Total IP occurrences: {ip_analysis['total_ip_occurrences']}")
        
        if ip_analysis['ip_counts']:
            print("   Top 10 IP addresses:")
            for ip, count in ip_analysis['ip_counts'].most_common(10):
                print(f"     {ip}: {count} occurrences")
        
        # SSH activity analysis
        print("\n3. SSH Activity Analysis:")
        ssh_analysis = self.analyze_ssh_activity(filepath)
        print(f"   Successful logins: {ssh_analysis['successful_count']}")
        print(f"   Failed login attempts: {ssh_analysis['failed_count']}")
        
        if ssh_analysis['failed_count'] > 0:
            failed_ips = Counter(login['ip'] for login in ssh_analysis['failed_logins'])
            print("   Top failed login IPs:")
            for ip, count in failed_ips.most_common(5):
                print(f"     {ip}: {count} attempts")
        
        # HTTP status codes (if applicable)
        print("\n4. HTTP Status Code Analysis:")
        http_analysis = self.analyze_http_status_codes(filepath)
        if http_analysis['total_requests'] > 0:
            print(f"   Total HTTP requests: {http_analysis['total_requests']}")
            print("   Status code distribution:")
            for status, count in sorted(http_analysis['status_counts'].items()):
                percentage = (count / http_analysis['total_requests']) * 100
                print(f"     {status}: {count} ({percentage:.1f}%)")
        else:
            print("   No HTTP status codes found")


def main():
    parser = argparse.ArgumentParser(description='Log Analysis Tool')
    parser.add_argument('logfile', help='Path to log file to analyze')
    parser.add_argument('-e', '--errors', action='store_true',
                        help='Show only errors and warnings')
    parser.add_argument('-i', '--ips', action='store_true',
                        help='Show only IP address analysis')
    parser.add_argument('-s', '--ssh', action='store_true',
                        help='Show only SSH activity analysis')
    parser.add_argument('-w', '--web', action='store_true',
                        help='Show only web server analysis')
    parser.add_argument('-p', '--pattern', type=str,
                        help='Search for custom pattern')
    parser.add_argument('-c', '--context', type=int, default=0,
                        help='Number of context lines to show with pattern matches')
    parser.add_argument('--case-sensitive', action='store_true',
                        help='Make pattern search case sensitive')
    parser.add_argument('--since', type=str,
                        help='Only analyze entries since this time (YYYY-MM-DD HH:MM:SS)')
    parser.add_argument('--until', type=str,
                        help='Only analyze entries until this time (YYYY-MM-DD HH:MM:SS)')
    
    args = parser.parse_args()
    
    analyzer = LogAnalyzer()
    
    # Parse time range if provided
    time_range = None
    if args.since or args.until:
        since = datetime.min
        until = datetime.max
        
        if args.since:
            since = datetime.strptime(args.since, "%Y-%m-%d %H:%M:%S")
        if args.until:
            until = datetime.strptime(args.until, "%Y-%m-%d %H:%M:%S")
        
        time_range = (since, until)
    
    # Handle specific analysis requests
    if args.pattern:
        print(f"Searching for pattern: {args.pattern}")
        results = analyzer.search_pattern(
            args.logfile, args.pattern, args.context, args.case_sensitive
        )
        print(f"Found {len(results)} matches:")
        for result in results:
            print(f"Line {result['line_number']}: {result['content']}")
            if 'context' in result:
                print("Context:")
                for context_line in result['context']:
                    print(f"  {context_line}")
                print()
    
    elif args.errors:
        results = analyzer.analyze_errors_warnings(args.logfile, time_range)
        print(f"Errors: {results['error_count']}, Warnings: {results['warning_count']}")
        for error in results['errors']:
            print(f"ERROR Line {error['line_number']}: {error['content']}")
        for warning in results['warnings']:
            print(f"WARN Line {warning['line_number']}: {warning['content']}")
    
    elif args.ips:
        results = analyzer.analyze_ip_addresses(args.logfile)
        print(f"Found {results['unique_ips']} unique IP addresses:")
        for ip, count in results['ip_counts'].most_common():
            print(f"{ip}: {count} occurrences")
    
    elif args.ssh:
        results = analyzer.analyze_ssh_activity(args.logfile)
        print(f"SSH Analysis - Success: {results['successful_count']}, Failed: {results['failed_count']}")
        print("\nFailed attempts:")
        for attempt in results['failed_logins']:
            print(f"{attempt['timestamp']}: {attempt['user']}@{attempt['ip']}")
    
    elif args.web:
        results = analyzer.analyze_http_status_codes(args.logfile)
        print(f"HTTP Status Code Analysis ({results['total_requests']} total requests):")
        for status, count in sorted(results['status_counts'].items()):
            percentage = (count / results['total_requests']) * 100 if results['total_requests'] > 0 else 0
            print(f"{status}: {count} ({percentage:.1f}%)")
    
    else:
        # Generate comprehensive report
        analyzer.generate_report(args.logfile)


if __name__ == "__main__":
    main()