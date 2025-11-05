-- Drop tables in reverse order of creation due to foreign key dependencies
DROP TABLE IF EXISTS Character_Species;
DROP TABLE IF EXISTS Series_Character;
DROP TABLE IF EXISTS Character;
DROP TABLE IF EXISTS Species;
DROP TABLE IF EXISTS Actor;
DROP TABLE IF EXISTS Series;
DROP VIEW IF EXISTS SeriesActors;
DROP PROC IF EXISTS GetSeriesActors;

-- create tables
CREATE TABLE Series (
    Id INT PRIMARY KEY,
    Name NVARCHAR(255) NOT NULL
);

CREATE TABLE Actor (
    Id INT PRIMARY KEY,
    FirstName NVARCHAR(100) NOT NULL,
    LastName NVARCHAR(100) NOT NULL,
    [BirthYear] INT NOT NULL,
    FullName AS (RTRIM(LTRIM(FirstName + ' ' + LastName))) PERSISTED
);

CREATE TABLE Species (
    Id INT PRIMARY KEY,
    Name NVARCHAR(255) NOT NULL
);

CREATE TABLE Character (
    Id INT PRIMARY KEY,
    Name NVARCHAR(255) NOT NULL,
    ActorId INT NOT NULL,
    Stardate DECIMAL(10, 2),
    FOREIGN KEY (ActorId) REFERENCES Actor(Id)
);

CREATE TABLE Series_Character (
    SeriesId INT,
    CharacterId INT,
    Role VARCHAR(500),
    FOREIGN KEY (SeriesId) REFERENCES Series(Id),
    FOREIGN KEY (CharacterId) REFERENCES Character(Id),
    PRIMARY KEY (SeriesId, CharacterId)
);

CREATE TABLE Character_Species (
    CharacterId INT,
    SpeciesId INT,
    FOREIGN KEY (CharacterId) REFERENCES Character(Id),
    FOREIGN KEY (SpeciesId) REFERENCES Species(Id),
    PRIMARY KEY (CharacterId, SpeciesId)
);

-- create data
INSERT INTO Series (Id, Name) VALUES 
    (1, 'Star Trek'),
    (2, 'Star Trek: The Next Generation'),
    (3, 'Star Trek: Voyager'),
    (4, 'Star Trek: Deep Space Nine'),
    (5, 'Star Trek: Enterprise');

INSERT INTO Species (Id, Name) VALUES 
    (1, 'Human'),
    (2, 'Vulcan'),
    (3, 'Android'),
    (4, 'Klingon'),
    (5, 'Betazoid'),
    (6, 'Hologram'),
    (7, 'Bajoran'),
    (8, 'Changeling'),
    (9, 'Trill'),
    (10, 'Ferengi'),
    (11, 'Denobulan'),
    (12, 'Borg');

INSERT INTO Actor (Id, FirstName, LastName, [BirthYear]) VALUES 
    (1, 'William', 'Shatner', 1931),
    (2, 'Leonard', 'Nimoy', 1931),
    (3, 'DeForest', 'Kelley', 1920),
    (4, 'James', 'Doohan', 1920),
    (5, 'Nichelle', 'Nichols', 1932),
    (6, 'George', 'Takei', 1937),
    (7, 'Walter', 'Koenig', 1936),
    (8, 'Patrick', 'Stewart', 1940),
    (9, 'Jonathan', 'Frakes', 1952),
    (10, 'Brent', 'Spiner', 1949),
    (11, 'Michael', 'Dorn', 1952),
    (12, 'Gates', 'McFadden', 1949),
    (13, 'Marina', 'Sirtis', 1955),
    (14, 'LeVar', 'Burton', 1957),
    (15, 'Kate', 'Mulgrew', 1955),
    (16, 'Robert', 'Beltran', 1953),
    (17, 'Tim', 'Russ', 1956),
    (18, 'Roxann', 'Dawson', 1958),
    (19, 'Robert', 'Duncan McNeill', 1964),
    (20, 'Garrett', 'Wang', 1968),
    (21, 'Robert', 'Picardo', 1953),
    (22, 'Jeri', 'Ryan', 1968),
    (23, 'Avery', 'Brooks', 1948),
    (24, 'Nana', 'Visitor', 1957),
    (25, 'Rene', 'Auberjonois', 1940),
    (26, 'Terry', 'Farrell', 1963),
    (27, 'Alexander', 'Siddig', 1965),
    (28, 'Armin', 'Shimerman', 1949),
    (29, 'Cirroc', 'Lofton', 1978),
    (30, 'Scott', 'Bakula', 1954),
    (31, 'Jolene', 'Blalock', 1975),
    (32, 'John', 'Billingsley', 1960),
    (33, 'Connor', 'Trinneer', 1969),
    (34, 'Dominic', 'Keating', 1962),
    (35, 'Linda', 'Park', 1978),
    (36, 'Anthony', 'Montgomery', 1971);

INSERT INTO Character (Id, Name, ActorId, Stardate) VALUES 
    (1, 'James T. Kirk', 1, 2233.04),
    (2, 'Spock', 2, 2230.06),
    (3, 'Leonard McCoy', 3, 2227.00),
    (4, 'Montgomery Scott', 4, 2222.00),
    (5, 'Uhura', 5, 2233.00),
    (6, 'Hikaru Sulu', 6, 2237.00),
    (7, 'Pavel Chekov', 7, 2245.00),
    (8, 'Jean-Luc Picard', 8, 2305.07),
    (9, 'William Riker', 9, 2335.08),
    (10, 'Data', 10, 2336.00),
    (11, 'Worf', 11, 2340.00),
    (12, 'Beverly Crusher', 12, 2324.00),
    (13, 'Deanna Troi', 13, 2336.00),
    (14, 'Geordi La Forge', 14, 2335.02),
    (15, 'Kathryn Janeway', 15, 2336.05),
    (16, 'Chakotay', 16, 2329.00),
    (17, 'Tuvok', 17, 2264.00),
    (18, 'B''Elanna Torres', 18, 2349.00),
    (19, 'Tom Paris', 19, 2346.00),
    (20, 'Harry Kim', 20, 2349.00),
    (21, 'The Doctor', 21, 2371.00),
    (22, 'Seven of Nine', 22, 2348.00),
    (23, 'Benjamin Sisko', 23, 2332.00),
    (24, 'Kira Nerys', 24, 2343.00),
    (25, 'Odo', 25, 2337.00),
    (26, 'Ezri Dax', 26, 2368.00),
    (27, 'Jadzia Dax', 26, 2341.00),
    (28, 'Julian Bashir', 27, 2341.00),
    (29, 'Quark', 28, 2333.00),
    (30, 'Jake Sisko', 29, 2355.00),
    (31, 'Jonathan Archer', 30, 2112.00),
    (32, 'T''Pol', 31, 2088.00),
    (33, 'Phlox', 32, 2102.00),
    (34, 'Charles "Trip" Tucker III', 33, 2121.00),
    (35, 'Malcolm Reed', 34, 2117.00),
    (36, 'Hoshi Sato', 35, 2129.00),
    (37, 'Travis Mayweather', 36, 2126.00);

GO
CREATE VIEW [dbo].[SeriesActors]
AS
SELECT
    a.Id AS Id,
    a.FullName AS Actor,
    a.BirthYear AS BirthYear,
    s.Id AS SeriesId,
    s.Name AS Series
FROM Series s
JOIN Series_Character AS sc ON s.Id = sc.SeriesId
JOIN Character AS c ON sc.CharacterId = c.Id
JOIN Actor AS a ON c.ActorId = a.Id;
GO

CREATE PROCEDURE [dbo].[GetSeriesActors]
    @seriesId INT = 1,
    @top INT = 5
AS
SET NOCOUNT ON;
SELECT TOP (@top) * 
FROM SeriesActors
WHERE SeriesId = @seriesId;
GO

-- demo indexes for performance
CREATE INDEX IX_Character_ActorId ON Character(ActorId);
CREATE INDEX IX_SeriesCharacter_SeriesId ON Series_Character(SeriesId);
CREATE INDEX IX_CharacterSpecies_CharacterId ON Character_Species(CharacterId);
