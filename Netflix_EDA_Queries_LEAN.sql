/* ============================================================================
   NETFLIX CONTENT ANALYSIS - COMPLETE SQL FILE (MySQL / MariaDB 8.0+)
   Lean version: uses LOAD DATA INFILE instead of inline INSERT statements.
   ============================================================================
   Dataset : netflix_titles.csv (8,807 titles: 6,131 Movies / 2,676 TV Shows)
   Dialect : MySQL 8.0+ / MariaDB 10.2+ (tested live against MariaDB 10.11)

   HOW TO RUN:
   1. Place these 3 files in the same folder as this .sql file (or update the
      paths below to point wherever they are):
        - netflix_cleaned.csv
        - netflix_countries.csv
        - netflix_genres.csv
   2. In MySQL Workbench, make sure local_infile is enabled:
        SHOW VARIABLES LIKE 'local_infile';   -- should say ON
        SET GLOBAL local_infile = 1;          -- if it says OFF
   3. Run this whole file (Ctrl+Shift+Enter, or lightning-bolt icon).

   DATA QUALITY FIXES APPLIED (found + fixed while testing this file against
   a live database with your real data — not hypothetical):
   1. 3 rows (Louis C.K. specials) had `rating` and `duration` swapped in the
      source CSV (rating showed "74 min" etc). Fixed duration and set
      rating to 'NR' (true rating unknown).
   2. 2 records ("The Land of the Enlightened..." desc, and the title
      "The Memphis Belle: A Story of a Flying Fortress") had a literal
      line-break character embedded inside a text field — a known quirk in
      this Kaggle dataset. This silently broke LOAD DATA INFILE: MySQL's
      line parser doesn't understand quoted embedded newlines the way
      pandas/Python's csv module does, so it read the first half of the
      title as its own row, corrupting row alignment for ~490 rows
      downstream in netflix_countries. Fixed by replacing embedded newlines
      with spaces during cleaning.
   3. date_added converted from DD-MM-YYYY text to proper DATE type.
   4. year_added/month_added converted from float to proper INT (NULL where
      date_added was originally missing, 10 rows).
   5. Query 3.7 / 7.2 used "/" for integer division, which is FLOAT division
      in MySQL/MariaDB (unlike SQLite/Postgres) — switched to DIV.
   6. Query 7.1 used PERCENTILE_CONT, unsupported in MySQL/MariaDB — replaced
      with a manual median via ROW_NUMBER()/COUNT() window functions.
   7. Query 9.8 used FULL OUTER JOIN, unsupported in MySQL/MariaDB — emulated
      with a LEFT JOIN + UNION of the mirrored LEFT JOIN.
   8. Query 9.7 had an ambiguous "country" column reference after the JOIN —
      qualified with the table alias.
   9. Query 4.2 used "IN (subquery ... LIMIT)", which MariaDB rejects (MySQL
      allows it) — rewritten as a CTE + JOIN for compatibility with both.

   This entire file — schema, data load, and all 40+ queries — was executed
   against a live MySQL-compatible server with your actual data, start to
   finish, with zero errors, before delivery.

   Sections:
     0. Schema (DDL) + data load (LOAD DATA INFILE)
     1. Data cleaning / quality checks
     2. Content type analysis
     3. Time trend analysis (growth, monthly heatmap)
     4. Geography analysis
     5. Genre analysis
     6. Rating analysis
     7. Duration analysis
     8. Director / Cast analysis
     9. Advanced / interview-style queries (window functions, CTEs, ranking)
   ========================================================================== */

-- ============================================================================
-- SECTION 0 : SCHEMA CREATION  (MySQL 8.0+)
-- ============================================================================
create database chill_netflix;
use chill_netflix;
DROP TABLE IF EXISTS netflix_countries;
DROP TABLE IF EXISTS netflix_titles;

CREATE TABLE netflix_titles (
    show_id          VARCHAR(10)  PRIMARY KEY,
    type              VARCHAR(10)  NOT NULL,
    title             VARCHAR(255) NOT NULL,
    director          VARCHAR(255),
    cast_members      TEXT,
    country           VARCHAR(255),
    primary_country   VARCHAR(100),
    date_added        DATE,
    year_added        INT,
    month_added       INT,
    month_name        VARCHAR(15),
    release_year      INT          NOT NULL,
    rating            VARCHAR(10),
    duration          VARCHAR(20),
    duration_int      INT,
    duration_unit     VARCHAR(10),
    listed_in         TEXT,
    primary_genre     VARCHAR(100),
    description       TEXT
) ENGINE=InnoDB;

CREATE TABLE netflix_countries (
    show_id       VARCHAR(10),
    title         VARCHAR(255),
    type          VARCHAR(10),
    release_year  INT,
    year_added    INT,
    country       VARCHAR(100),
    FOREIGN KEY (show_id) REFERENCES netflix_titles(show_id)
) ENGINE=InnoDB;

CREATE TABLE netflix_genres (
    show_id        VARCHAR(10),
    title          VARCHAR(255),
    type           VARCHAR(10),
    release_year   INT,
    year_added     INT,
    primary_country VARCHAR(100),
    genre          VARCHAR(100),
    FOREIGN KEY (show_id) REFERENCES netflix_titles(show_id)
) ENGINE=InnoDB;

SET GLOBAL local_infile = 1;
SHOW GLOBAL VARIABLES LIKE 'local_infile';

/* ============================================================================
   DATA LOAD
   ========================================================================== */
LOAD DATA LOCAL INFILE 'C:/Users/91895/Desktop/Timepass/Netflix/claude_files/sqlm/netflix_cleaned.csv'
INTO TABLE netflix_titles
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(show_id, type, title, director, cast_members, country, primary_country,
 @date_added, @year_added, @month_added, month_name, release_year, rating,
 duration, duration_int, duration_unit, listed_in, primary_genre, description)
SET
    date_added  = NULLIF(@date_added, ''),
    year_added  = NULLIF(@year_added, ''),
    month_added = NULLIF(@month_added, '');

LOAD DATA LOCAL INFILE 'C:/Users/91895/Desktop/Timepass/Netflix/claude_files/sqlm/netflix_countries.csv'
INTO TABLE netflix_countries
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(show_id, title, type, release_year, @year_added, country)
SET
    year_added = NULLIF(@year_added, '');

LOAD DATA LOCAL INFILE 'C:/Users/91895/Desktop/Timepass/Netflix/claude_files/sqlm/netflix_genres.csv'
INTO TABLE netflix_genres
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(show_id, title, type, release_year, @year_added, primary_country, genre)
SET
    year_added = NULLIF(@year_added, '');

CREATE INDEX idx_titles_type   ON netflix_titles(type);
CREATE INDEX idx_titles_year   ON netflix_titles(year_added);
CREATE INDEX idx_countries_ctr ON netflix_countries(country);
CREATE INDEX idx_genres_genre  ON netflix_genres(genre);


/* ============================================================================
   SECTION 1 : DATA CLEANING / QUALITY CHECKS
   ========================================================================== */

-- 1.1 Row count & duplicate show_id check
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT show_id) AS unique_ids
FROM netflix_titles;

-- 1.2 Null / missing value audit per column
SELECT
    SUM(CASE WHEN director        IS NULL OR director = ''        THEN 1 ELSE 0 END) AS null_director,
    SUM(CASE WHEN country         IS NULL OR country = ''         THEN 1 ELSE 0 END) AS null_country,
    SUM(CASE WHEN date_added      IS NULL                          THEN 1 ELSE 0 END) AS null_date_added,
    SUM(CASE WHEN rating          IS NULL OR rating = ''           THEN 1 ELSE 0 END) AS null_rating,
    SUM(CASE WHEN cast_members    IS NULL OR cast_members = ''     THEN 1 ELSE 0 END) AS null_cast
FROM netflix_titles;

-- 1.3 Duplicate titles (same title & release_year appearing more than once)
SELECT title, release_year, COUNT(*) AS occurrences
FROM netflix_titles
GROUP BY title, release_year
HAVING COUNT(*) > 1;

-- 1.4 Rows where release_year is implausible (sanity check)
SELECT * FROM netflix_titles
WHERE release_year < 1925 OR release_year > YEAR(CURDATE());


/* ============================================================================
   SECTION 2 : CONTENT TYPE ANALYSIS
   ========================================================================== */

-- 2.1 Movies vs TV Shows — count and % share
SELECT
    type,
    COUNT(*) AS title_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_share
FROM netflix_titles
GROUP BY type
ORDER BY title_count DESC;


/* ============================================================================
   SECTION 3 : TIME TREND ANALYSIS
   ========================================================================== */

-- 3.1 Titles added per year (overall growth curve)
SELECT year_added, COUNT(*) AS titles_added
FROM netflix_titles
WHERE year_added IS NOT NULL
GROUP BY year_added
ORDER BY year_added;

-- 3.2 Year-over-year growth rate (%) using window function LAG
SELECT
    year_added,
    COUNT(*) AS titles_added,
    LAG(COUNT(*)) OVER (ORDER BY year_added) AS prev_year_titles,
    ROUND(100.0 * (COUNT(*) - LAG(COUNT(*)) OVER (ORDER BY year_added))
          / NULLIF(LAG(COUNT(*)) OVER (ORDER BY year_added), 0), 1) AS yoy_growth_pct
FROM netflix_titles
WHERE year_added IS NOT NULL
GROUP BY year_added
ORDER BY year_added;

-- 3.3 Peak year for content addition
SELECT year_added, COUNT(*) AS titles_added
FROM netflix_titles
WHERE year_added IS NOT NULL
GROUP BY year_added
ORDER BY titles_added DESC
LIMIT 1;

-- 3.4 Monthly heatmap: titles added by Year x Month
SELECT
    year_added,
    month_name,
    COUNT(*) AS titles_added
FROM netflix_titles
WHERE year_added IS NOT NULL
GROUP BY year_added, month_name
ORDER BY year_added, MIN(month_added);

-- 3.5 Which month (across all years) gets the most content added?
SELECT month_name, COUNT(*) AS titles_added
FROM netflix_titles
WHERE month_name IS NOT NULL
GROUP BY month_name
ORDER BY titles_added DESC;

-- 3.6 Gap between release_year and year_added (how "fresh" is Netflix content?)
SELECT
    (year_added - release_year) AS years_after_release,
    COUNT(*) AS title_count
FROM netflix_titles
WHERE year_added IS NOT NULL
GROUP BY (year_added - release_year)
ORDER BY years_after_release;

-- 3.7 Content released per decade
-- NOTE (fixed for MySQL): "/" performs float division in MySQL, unlike SQLite/Postgres
-- integer division. Use DIV for true integer division, or FLOOR().
SELECT
    (release_year DIV 10) * 10 AS release_decade,
    COUNT(*) AS title_count
FROM netflix_titles
GROUP BY (release_year DIV 10) * 10
ORDER BY release_decade;


/* ============================================================================
   SECTION 4 : GEOGRAPHY ANALYSIS
   ========================================================================== */

-- 4.1 Top 10 content-producing countries
SELECT country, COUNT(*) AS title_count
FROM netflix_countries
WHERE country IS NOT NULL AND country <> 'Unknown'
GROUP BY country
ORDER BY title_count DESC
LIMIT 10;

-- 4.2 Movies vs TV Shows split within each top country
-- NOTE (fixed): rewritten as a CTE + JOIN instead of "IN (subquery ... LIMIT)",
-- since MariaDB (unlike MySQL) rejects LIMIT inside an IN subquery.
WITH top5_countries AS (
    SELECT country FROM netflix_countries
    WHERE country <> 'Unknown'
    GROUP BY country ORDER BY COUNT(*) DESC LIMIT 5
)
SELECT nc.country, nc.type, COUNT(*) AS title_count
FROM netflix_countries nc
JOIN top5_countries t5 ON nc.country = t5.country
GROUP BY nc.country, nc.type
ORDER BY nc.country, nc.type;

-- 4.3 Countries with the highest share of TV-MA rated (mature) content
SELECT c.country,
       ROUND(100.0 * SUM(CASE WHEN t.rating = 'TV-MA' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_tv_ma
FROM netflix_countries c
JOIN netflix_titles t ON c.show_id = t.show_id
WHERE c.country <> 'Unknown'
GROUP BY c.country
HAVING COUNT(*) >= 50
ORDER BY pct_tv_ma DESC
LIMIT 10;


/* ============================================================================
   SECTION 5 : GENRE ANALYSIS
   ========================================================================== */

-- 5.1 Top 10 most popular genres overall
SELECT genre, COUNT(*) AS title_count
FROM netflix_genres
GROUP BY genre
ORDER BY title_count DESC
LIMIT 10;

-- 5.2 Top 5 genre trends year over year
SELECT year_added, genre, COUNT(*) AS title_count
FROM netflix_genres
WHERE genre IN ('International Movies','Dramas','Comedies','International TV Shows','Documentaries')
  AND year_added IS NOT NULL
GROUP BY year_added, genre
ORDER BY year_added, genre;

-- 5.3 Genre popularity by content type (which genres are Movie-only vs TV-only)
SELECT genre, type, COUNT(*) AS title_count
FROM netflix_genres
GROUP BY genre, type
ORDER BY genre, title_count DESC;

-- 5.4 Average number of genres tagged per title
-- NOTE: source data (Netflix "listed_in" field) caps at 3 genres/title.
SELECT AVG(genre_count) AS avg_genres_per_title
FROM (
    SELECT show_id, COUNT(*) AS genre_count
    FROM netflix_genres
    GROUP BY show_id
) g;


/* ============================================================================
   SECTION 6 : RATING ANALYSIS
   ========================================================================== */

-- 6.1 Overall content rating distribution
SELECT rating, COUNT(*) AS title_count
FROM netflix_titles
WHERE rating IS NOT NULL AND rating <> ''
GROUP BY rating
ORDER BY title_count DESC;

-- 6.2 Rating distribution split by content type
SELECT rating, type, COUNT(*) AS title_count
FROM netflix_titles
WHERE rating IS NOT NULL AND rating <> ''
GROUP BY rating, type
ORDER BY title_count DESC;

-- 6.3 % of "mature" (TV-MA / R / NC-17) content vs "family friendly" (G / TV-G / PG / TV-Y)
SELECT
    CASE
        WHEN rating IN ('TV-MA','R','NC-17') THEN 'Mature'
        WHEN rating IN ('G','TV-G','PG','TV-Y','TV-Y7','TV-Y7-FV') THEN 'Family/Kids'
        ELSE 'Teen/Other'
    END AS rating_bucket,
    COUNT(*) AS title_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_share
FROM netflix_titles
GROUP BY rating_bucket
ORDER BY title_count DESC;


/* ============================================================================
   SECTION 7 : DURATION ANALYSIS
   ========================================================================== */

-- 7.1 Movie duration summary stats
-- NOTE (fixed for MySQL): PERCENTILE_CONT is not supported in MySQL/MariaDB.
-- Median calculated manually via ROW_NUMBER() + COUNT() window functions (MySQL 8.0+).
SELECT
    (SELECT MIN(duration_int) FROM netflix_titles WHERE type = 'Movie') AS min_minutes,
    (SELECT MAX(duration_int) FROM netflix_titles WHERE type = 'Movie') AS max_minutes,
    (SELECT ROUND(AVG(duration_int), 1) FROM netflix_titles WHERE type = 'Movie') AS avg_minutes,
    (SELECT AVG(duration_int) FROM (
        SELECT duration_int,
               ROW_NUMBER() OVER (ORDER BY duration_int) AS rn,
               COUNT(*) OVER () AS cnt
        FROM netflix_titles WHERE type = 'Movie'
    ) x WHERE rn IN (FLOOR((cnt + 1) / 2), FLOOR((cnt + 2) / 2))) AS median_minutes;

-- 7.2 Movie duration histogram buckets (10-minute bins)
-- NOTE (fixed for MySQL): integer division via DIV, not "/".
SELECT
    (duration_int DIV 10) * 10 AS duration_bucket,
    COUNT(*) AS movie_count
FROM netflix_titles
WHERE type = 'Movie'
GROUP BY (duration_int DIV 10) * 10
ORDER BY duration_bucket;

-- 7.3 Top 10 longest movies
SELECT title, duration_int AS minutes, release_year, primary_country
FROM netflix_titles
WHERE type = 'Movie'
ORDER BY duration_int DESC
LIMIT 10;

-- 7.4 Top 10 shortest movies (excluding likely data errors under 5 min)
SELECT title, duration_int AS minutes, release_year, primary_country
FROM netflix_titles
WHERE type = 'Movie' AND duration_int >= 5
ORDER BY duration_int ASC
LIMIT 10;

-- 7.5 TV Shows: distribution of number of seasons
SELECT duration_int AS seasons, COUNT(*) AS show_count
FROM netflix_titles
WHERE type = 'TV Show'
GROUP BY duration_int
ORDER BY seasons;

-- 7.6 TV Shows with the most seasons (long-running franchises)
SELECT title, duration_int AS seasons, release_year, primary_country
FROM netflix_titles
WHERE type = 'TV Show'
ORDER BY duration_int DESC
LIMIT 10;


/* ============================================================================
   SECTION 8 : DIRECTOR & CAST ANALYSIS
   ========================================================================== */

-- 8.1 Top 10 most prolific directors
SELECT director, COUNT(*) AS title_count
FROM netflix_titles
WHERE director IS NOT NULL AND director <> '' AND director <> 'Unknown'
GROUP BY director
ORDER BY title_count DESC
LIMIT 10;

-- 8.2 Directors who work across both Movies and TV Shows
SELECT director, COUNT(DISTINCT type) AS content_types
FROM netflix_titles
WHERE director IS NOT NULL AND director <> 'Unknown'
GROUP BY director
HAVING COUNT(DISTINCT type) > 1;

-- 8.3 Top director per country (window function)
SELECT country, director, title_count FROM (
    SELECT
        t.primary_country AS country,
        t.director,
        COUNT(*) AS title_count,
        RANK() OVER (PARTITION BY t.primary_country ORDER BY COUNT(*) DESC) AS rnk
    FROM netflix_titles t
    WHERE t.director <> 'Unknown' AND t.primary_country <> 'Unknown'
    GROUP BY t.primary_country, t.director
) ranked
WHERE rnk = 1
ORDER BY title_count DESC
LIMIT 15;


/* ============================================================================
   SECTION 9 : ADVANCED / INTERVIEW-STYLE QUERIES
   ========================================================================== */

-- 9.1 Running (cumulative) total of titles added by year
SELECT
    year_added,
    COUNT(*) AS titles_added,
    SUM(COUNT(*)) OVER (ORDER BY year_added) AS cumulative_titles
FROM netflix_titles
WHERE year_added IS NOT NULL
GROUP BY year_added
ORDER BY year_added;

-- 9.2 Rank countries by titles added, per year (top 3 per year) — CTE + window fn
WITH country_year AS (
    SELECT year_added, country, COUNT(*) AS title_count
    FROM netflix_countries
    WHERE year_added IS NOT NULL AND country <> 'Unknown'
    GROUP BY year_added, country
),
ranked AS (
    SELECT *,
           DENSE_RANK() OVER (PARTITION BY year_added ORDER BY title_count DESC) AS rnk
    FROM country_year
)
SELECT year_added, country, title_count
FROM ranked
WHERE rnk <= 3
ORDER BY year_added, rnk;

-- 9.3 Titles that belong to more than 3 genres (heavily cross-tagged content)
-- NOTE: returns 0 rows by design — this dataset's "listed_in" field never lists more
-- than 3 genres per title, so this correctly finds none. Query kept for portfolio value.
SELECT t.title, t.type, g.genre_count
FROM netflix_titles t
JOIN (
    SELECT show_id, COUNT(*) AS genre_count
    FROM netflix_genres
    GROUP BY show_id
    HAVING COUNT(*) > 3
) g ON t.show_id = g.show_id
ORDER BY g.genre_count DESC;

-- 9.4 Titles added to Netflix the same year they were released ("day-and-date" releases)
SELECT COUNT(*) AS same_year_releases,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM netflix_titles WHERE year_added IS NOT NULL), 1) AS pct_of_total
FROM netflix_titles
WHERE year_added = release_year;

-- 9.5 Self-join: pairs of titles released in the same year & same primary_genre
SELECT a.title AS title_1, b.title AS title_2, a.release_year, a.primary_genre
FROM netflix_titles a
JOIN netflix_titles b
  ON a.release_year = b.release_year
 AND a.primary_genre = b.primary_genre
 AND a.show_id < b.show_id
WHERE a.release_year = 2020 AND a.primary_genre = 'Dramas'
LIMIT 20;

-- 9.6 Quartile rank of each movie's duration (NTILE)
SELECT title, duration_int,
       NTILE(4) OVER (ORDER BY duration_int) AS duration_quartile
FROM netflix_titles
WHERE type = 'Movie';

-- 9.7 First and most recent title added, per country (FIRST_VALUE)
-- NOTE (fixed): qualified "country" with alias c. to remove ambiguity with joined table.
SELECT DISTINCT
    c.country,
    FIRST_VALUE(t.title) OVER (PARTITION BY c.country ORDER BY t.date_added)      AS first_title_added,
    FIRST_VALUE(t.title) OVER (PARTITION BY c.country ORDER BY t.date_added DESC) AS most_recent_title_added
FROM netflix_countries c
JOIN netflix_titles t ON c.show_id = t.show_id
WHERE c.country <> 'Unknown';

-- 9.8 Which genres grew fastest between 2018 and 2021?
-- NOTE (fixed for MySQL): FULL OUTER JOIN is not supported in MySQL/MariaDB.
-- Emulated with LEFT JOIN + UNION of the mirrored LEFT JOIN.
WITH g_2018 AS (
    SELECT genre, COUNT(*) AS c18 FROM netflix_genres WHERE year_added = 2018 GROUP BY genre
),
g_2021 AS (
    SELECT genre, COUNT(*) AS c21 FROM netflix_genres WHERE year_added = 2021 GROUP BY genre
)
SELECT genre, titles_2018, titles_2021, net_change FROM (
    SELECT
        g18.genre AS genre,
        COALESCE(c18, 0) AS titles_2018,
        COALESCE(c21, 0) AS titles_2021,
        COALESCE(c21, 0) - COALESCE(c18, 0) AS net_change
    FROM g_2018 g18
    LEFT JOIN g_2021 g21 ON g18.genre = g21.genre

    UNION

    SELECT
        g21.genre AS genre,
        COALESCE(c18, 0) AS titles_2018,
        COALESCE(c21, 0) AS titles_2021,
        COALESCE(c21, 0) - COALESCE(c18, 0) AS net_change
    FROM g_2021 g21
    LEFT JOIN g_2018 g18 ON g18.genre = g21.genre
) combined
ORDER BY net_change DESC
LIMIT 10;

-- 9.9 Flag "binge-worthy" long TV shows (4+ seasons) vs limited series (1 season)
SELECT
    CASE WHEN duration_int = 1 THEN 'Limited Series (1 season)'
         WHEN duration_int BETWEEN 2 AND 3 THEN 'Short Run (2-3 seasons)'
         ELSE 'Long Running (4+ seasons)'
    END AS series_length_bucket,
    COUNT(*) AS show_count
FROM netflix_titles
WHERE type = 'TV Show'
GROUP BY series_length_bucket
ORDER BY show_count DESC;

/* ============================================================================
   END OF FILE
   ========================================================================== */
