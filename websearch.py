#!/usr/bin/env python3
"""
Web search and page fetch tool using Scrapy + curl_cffi for anti-detection.
Bypasses Bing/Baidu bot detection via TLS fingerprint impersonation.

Dependencies:
    pip install scrapy scrapy-impersonate

Usage:
    # Search (query is not a URL)
    websearch "your search query"
    websearch "your search query" --engine baidu
    websearch "your search query" --max-results 10
    websearch "your search query" --json

    # Fetch page (query starts with http/https)
    websearch "https://example.com"
    websearch "https://example.com" --json

    # Tests
    websearch --test
"""
import sys
import json
import argparse
import logging
from urllib.parse import quote_plus

# Suppress all logging before importing scrapy
logging.disable(logging.CRITICAL)

import scrapy
from scrapy.crawler import CrawlerProcess
from scrapy import signals
from scrapy.http import HtmlResponse


# Random real Chrome UA
CHROME_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)


class SearchResult(scrapy.Item):
    title = scrapy.Field()
    url = scrapy.Field()
    snippet = scrapy.Field()


class BingSearchSpider(scrapy.Spider):
    name = "bing_search"
    custom_settings = {
        "DOWNLOAD_HANDLERS": {
            "https": "scrapy_impersonate.ImpersonateDownloadHandler",
        },
        "TWISTED_REACTOR": "twisted.internet.asyncioreactor.AsyncioSelectorReactor",
        "ROBOTSTXT_OBEY": False,
        "DEFAULT_REQUEST_HEADERS": {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Accept-Encoding": "gzip, deflate, br",
            "Connection": "keep-alive",
        },
        "USER_AGENT": CHROME_UA,
        "DOWNLOAD_DELAY": 1,
        "CONCURRENT_REQUESTS": 1,
        "HTTPCACHE_ENABLED": False,
        "LOG_LEVEL": "CRITICAL",
    }

    def __init__(self, query, max_results=10, **kwargs):
        super().__init__(**kwargs)
        self.query = query
        self.max_results = max_results
        self.results = []

    def _extract_real_url(self, bing_url):
        """Extract real URL from Bing redirect URL."""
        from urllib.parse import urlparse, parse_qs
        try:
            parsed = urlparse(bing_url)
            if "/ck/a" in parsed.path or "bing.com/ck" in bing_url:
                params = parse_qs(parsed.query)
                if 'u' in params:
                    encoded_url = params['u'][0]
                    if encoded_url.startswith('a1'):
                        encoded_url = encoded_url[2:]
                    import base64
                    try:
                        decoded = base64.b64decode(encoded_url + '==').decode('utf-8')
                        return decoded
                    except:
                        pass
            return bing_url
        except:
            return bing_url

    def start_requests(self):
        url = f"https://www.bing.com/search?q={quote_plus(self.query)}&count={self.max_results + 10}"
        yield scrapy.Request(
            url,
            meta={
                "impersonate": "chrome120",
            },
            dont_filter=True,
        )

    def parse(self, response):
        count = 0
        for sel in response.css("li.b_algo"):
            if count >= self.max_results:
                break
            title_el = sel.css("h2 a")
            title = title_el.css("::text").get("").strip()
            url = title_el.css("::attr(href)").get("")
            snippet = sel.css("div.b_caption p::text").get("").strip()
            if title and url:
                real_url = self._extract_real_url(url)
                yield SearchResult(title=title, url=real_url, snippet=snippet)
                count += 1

        if count == 0:
            for sel in response.css("ol#b_results li"):
                if count >= self.max_results:
                    break
                title_el = sel.css("h2 a")
                title = title_el.css("::text").get("").strip()
                url = title_el.css("::attr(href)").get("")
                snippet = sel.css("p::text, div::text").get("").strip()
                if title and url and url.startswith("http"):
                    real_url = self._extract_real_url(url)
                    yield SearchResult(title=title, url=real_url, snippet=snippet)
                    count += 1


class BaiduSearchSpider(scrapy.Spider):
    name = "baidu_search"
    custom_settings = {
        "DOWNLOAD_HANDLERS": {
            "https": "scrapy_impersonate.ImpersonateDownloadHandler",
        },
        "TWISTED_REACTOR": "twisted.internet.asyncioreactor.AsyncioSelectorReactor",
        "ROBOTSTXT_OBEY": False,
        "DEFAULT_REQUEST_HEADERS": {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Accept-Encoding": "gzip, deflate, br",
            "Connection": "keep-alive",
        },
        "USER_AGENT": CHROME_UA,
        "DOWNLOAD_DELAY": 1,
        "CONCURRENT_REQUESTS": 1,
        "HTTPCACHE_ENABLED": False,
        "LOG_LEVEL": "CRITICAL",
    }

    def __init__(self, query, max_results=10, **kwargs):
        super().__init__(**kwargs)
        self.query = query
        self.max_results = max_results

    def _extract_real_url(self, baidu_url):
        """Extract real URL from Baidu redirect URL."""
        from urllib.parse import urlparse, parse_qs
        try:
            parsed = urlparse(baidu_url)
            if "baidu.com/link" in baidu_url:
                params = parse_qs(parsed.query)
                if 'url' in params:
                    return params['url'][0]
            return baidu_url
        except:
            return baidu_url

    def start_requests(self):
        url = f"https://www.baidu.com/s?wd={quote_plus(self.query)}&rn={self.max_results}"
        yield scrapy.Request(
            url,
            meta={
                "impersonate": "chrome120",
            },
            dont_filter=True,
        )

    def parse(self, response):
        for sel in response.css("div.result, div.c-container"):
            title_el = sel.css("h3 a")
            title = title_el.css("::text").get("").strip()
            url = title_el.css("::attr(href)").get("")
            snippet = sel.css("div.c-abstract::text, span.content-right_8Zs40::text").get("").strip()
            if title and url:
                real_url = self._extract_real_url(url)
                yield SearchResult(title=title, url=real_url, snippet=snippet)


class PageFetchSpider(scrapy.Spider):
    name = "page_fetch"
    custom_settings = {
        "DOWNLOAD_HANDLERS": {
            "https": "scrapy_impersonate.ImpersonateDownloadHandler",
        },
        "TWISTED_REACTOR": "twisted.internet.asyncioreactor.AsyncioSelectorReactor",
        "ROBOTSTXT_OBEY": False,
        "DEFAULT_REQUEST_HEADERS": {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Accept-Encoding": "gzip, deflate, br",
            "Connection": "keep-alive",
        },
        "USER_AGENT": CHROME_UA,
        "DOWNLOAD_DELAY": 1,
        "CONCURRENT_REQUESTS": 1,
        "HTTPCACHE_ENABLED": False,
        "LOG_LEVEL": "CRITICAL",
    }

    def __init__(self, url, **kwargs):
        super().__init__(**kwargs)
        self.url = url

    def start_requests(self):
        yield scrapy.Request(
            self.url,
            meta={"impersonate": "chrome120"},
            dont_filter=True,
        )

    def parse(self, response):
        title = response.css("title::text").get("").strip()
        meta_desc = response.css('meta[name="description"]::attr(content)').get("").strip()
        meta_keywords = response.css('meta[name="keywords"]::attr(content)').get("").strip()

        # Extract main text content
        text_parts = []
        for elem in response.css("body *"):
            tag = elem.root.tag
            if tag in ('script', 'style', 'noscript', 'header', 'footer', 'nav'):
                continue
            text = elem.css("::text").get("").strip()
            if text and len(text) > 10:
                text_parts.append(text)

        content = " ".join(text_parts[:50])[:2000]

        yield {
            "url": response.url,
            "title": title,
            "meta_description": meta_desc,
            "meta_keywords": meta_keywords,
            "content": content,
        }


def run_search(query, engine="bing", max_results=10):
    results = []

    spider_map = {
        "bing": BingSearchSpider,
        "baidu": BaiduSearchSpider,
    }
    spider_cls = spider_map.get(engine, BingSearchSpider)

    process = CrawlerProcess()

    crawler = process.create_crawler(spider_cls)

    def collect_item(item, response, spider):
        results.append(dict(item))

    crawler.signals.connect(collect_item, signal=signals.item_scraped)

    process.crawl(crawler, query=query, max_results=max_results)
    process.start()

    return results


def fetch_page(url):
    """Fetch content from a URL."""
    results = []

    process = CrawlerProcess()

    crawler = process.create_crawler(PageFetchSpider)

    def collect_item(item, response, spider):
        results.append(dict(item))

    crawler.signals.connect(collect_item, signal=signals.item_scraped)

    process.crawl(crawler, url=url)
    process.start()

    return results[0] if results else None


def run_tests():
    """Run built-in tests."""
    total = 0
    passed = 0
    failed = 0
    all_results = {}

    def test(name, result):
        nonlocal total, passed, failed
        total += 1
        print(f"Test {total}: {name}")
        if result:
            print("  ✓ PASS")
            passed += 1
        else:
            print("  ✗ FAIL")
            failed += 1

    # Create a combined spider for all tests
    class TestSpider(scrapy.Spider):
        name = "test_spider"
        custom_settings = {
            "DOWNLOAD_HANDLERS": {"https": "scrapy_impersonate.ImpersonateDownloadHandler"},
            "TWISTED_REACTOR": "twisted.internet.asyncioreactor.AsyncioSelectorReactor",
            "ROBOTSTXT_OBEY": False,
            "DEFAULT_REQUEST_HEADERS": {
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
                "Accept-Encoding": "gzip, deflate, br",
                "Connection": "keep-alive",
            },
            "USER_AGENT": CHROME_UA,
            "DOWNLOAD_DELAY": 1,
            "CONCURRENT_REQUESTS": 3,
            "HTTPCACHE_ENABLED": False,
            "LOG_LEVEL": "CRITICAL",
        }

        def __init__(self, **kwargs):
            super().__init__(**kwargs)
            self.results = {}

        def start_requests(self):
            # Search test
            yield scrapy.Request(
                "https://www.bing.com/search?q=github&count=3",
                meta={"impersonate": "chrome120", "test_type": "search"},
                dont_filter=True,
            )
            # Page fetch tests
            for url in ["https://example.com", "https://example.org", "https://info.cern.ch"]:
                yield scrapy.Request(
                    url,
                    meta={"impersonate": "chrome120", "test_type": "fetch"},
                    dont_filter=True,
                )

        def parse(self, response):
            test_type = response.meta.get("test_type")

            if test_type == "search":
                results = []
                for sel in response.css("li.b_algo")[:2]:
                    title_el = sel.css("h2 a")
                    title = title_el.css("::text").get("").strip()
                    url = title_el.css("::attr(href)").get("")
                    if title and url:
                        # Extract real URL
                        from urllib.parse import urlparse, parse_qs
                        try:
                            parsed = urlparse(url)
                            if "/ck/a" in parsed.path or "bing.com/ck" in url:
                                params = parse_qs(parsed.query)
                                if 'u' in params:
                                    encoded_url = params['u'][0]
                                    if encoded_url.startswith('a1'):
                                        encoded_url = encoded_url[2:]
                                    import base64
                                    try:
                                        url = base64.b64decode(encoded_url + '==').decode('utf-8')
                                    except:
                                        pass
                        except:
                            pass
                        results.append({"title": title, "url": url})
                self.results["search"] = results

            elif test_type == "fetch":
                title = response.css("title::text").get("").strip()
                content_parts = []
                for elem in response.css("body *"):
                    tag = elem.root.tag
                    if tag in ('script', 'style', 'noscript', 'header', 'footer', 'nav'):
                        continue
                    text = elem.css("::text").get("").strip()
                    if text and len(text) > 10:
                        content_parts.append(text)
                content = " ".join(content_parts[:50])[:2000]
                self.results[response.url.rstrip('/')] = {"title": title, "content": content}

    # Run all tests in a single Scrapy process
    process = CrawlerProcess()
    crawler = process.create_crawler(TestSpider)

    class ResultCollector:
        def __init__(self):
            self.results = {}

        def collect(self, spider):
            self.results = spider.results

    collector = ResultCollector()
    crawler.signals.connect(collector.collect, signal=signals.spider_closed)

    process.crawl(crawler)
    process.start()

    # Analyze results
    all_results = collector.results
    if not all_results:
        print("No results collected!")
        return False

    print("=== Search Tests ===")
    search_results = all_results.get("search", [])
    test("Search returns results", len(search_results) > 0)
    test("Search result has title", search_results[0].get("title", "") if search_results else False)
    test("Search result has url", search_results[0].get("url", "") if search_results else False)
    test("URL is not Bing redirect",
         "bing.com/ck" not in search_results[0].get("url", "") if search_results else False)

    print("\n=== Page Fetch Tests (Static Pages) ===")

    # Test example.com
    page1 = all_results.get("https://example.com")
    test("Fetch example.com", page1 is not None)
    test("example.com has title", page1.get("title", "") if page1 else False)
    test("example.com title is 'Example Domain'",
         "Example Domain" in page1.get("title", "") if page1 else False)
    test("example.com has content", len(page1.get("content", "")) > 0 if page1 else False)

    # Test example.org
    page2 = all_results.get("https://example.org")
    test("Fetch example.org", page2 is not None)
    test("example.org has title", page2.get("title", "") if page2 else False)

    # Test info.cern.ch
    page3 = all_results.get("https://info.cern.ch")
    test("Fetch info.cern.ch", page3 is not None)
    test("info.cern.ch has title", page3.get("title", "") if page3 else False)

    # Summary
    print("=" * 50)
    print(f"Total: {total}")
    print(f"Passed: {passed}")
    print(f"Failed: {failed}")
    print("=" * 50)

    if failed == 0:
        print("🎉 All tests passed!")
    else:
        print(f"⚠️  {failed} test(s) failed")

    return failed == 0

    # Test example.com
    page1 = all_results.get("https://example.com")
    test("Fetch example.com", page1 is not None)
    test("example.com has title", page1.get("title", "") if page1 else False)
    test("example.com title is 'Example Domain'",
         "Example Domain" in page1.get("title", "") if page1 else False)
    test("example.com has content", len(page1.get("content", "")) > 0 if page1 else False)

    # Test example.org
    page2 = all_results.get("https://example.org")
    test("Fetch example.org", page2 is not None)
    test("example.org has title", page2.get("title", "") if page2 else False)

    # Test info.cern.ch
    page3 = all_results.get("https://info.cern.ch")
    test("Fetch info.cern.ch", page3 is not None)
    test("info.cern.ch has title", page3.get("title", "") if page3 else False)

    # Summary
    print("=" * 50)
    print(f"Total: {total}")
    print(f"Passed: {passed}")
    print(f"Failed: {failed}")
    print("=" * 50)

    if failed == 0:
        print("🎉 All network tests passed!")
    else:
        print(f"⚠️  {failed} test(s) failed")

    return failed == 0


def main():
    parser = argparse.ArgumentParser(description="Web search and page fetch tool")
    parser.add_argument("query", nargs="?", help="Search query or URL (if starts with http/https)")
    parser.add_argument("--engine", choices=["bing", "baidu"], default="bing", help="Search engine (default: bing)")
    parser.add_argument("--max-results", type=int, default=10, help="Max results (default: 10)")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--test", action="store_true", help="Run built-in tests")
    args = parser.parse_args()

    if args.test:
        success = run_tests()
        sys.exit(0 if success else 1)

    if not args.query:
        parser.error("query is required (or use --test)")

    # Check if query is a URL
    if args.query.startswith("http://") or args.query.startswith("https://"):
        # Fetch mode
        result = fetch_page(args.query)
        if not result:
            print("Failed to fetch page.")
            sys.exit(1)

        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(f"URL: {result.get('url', '')}")
            print(f"Title: {result.get('title', '')}")
            if result.get('meta_description'):
                print(f"Description: {result['meta_description']}")
            if result.get('meta_keywords'):
                print(f"Keywords: {result['meta_keywords']}")
            print()
            content = result.get('content', '')
            if content:
                print("Content:")
                print(content[:2000])
    else:
        # Search mode
        results = run_search(args.query, engine=args.engine, max_results=args.max_results)

        if args.json:
            print(json.dumps(results, ensure_ascii=False, indent=2))
        else:
            if not results:
                print("No results found.")
                return
            for i, r in enumerate(results, 1):
                print(f"{i}. {r['title']}")
                print(f"   {r['url']}")
                if r.get("snippet"):
                    print(f"   {r['snippet'][:120]}")
                print()


if __name__ == "__main__":
    main()
