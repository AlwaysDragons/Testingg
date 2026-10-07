"""Poster-specific selectors — new-listing forms per platform."""
from __future__ import annotations


class DepopNew:
    URL = "https://www.depop.com/products/create/"
    PHOTOS_INPUT = "input[type='file'][accept*='image']"
    TITLE_INPUT = "input[name='title']"
    DESC_TEXTAREA = "textarea[name='description']"
    CATEGORY_SELECT = "button[data-testid='category-select']"
    SIZE_SELECT = "button[data-testid='size-select']"
    PRICE_INPUT = "input[name='price']"
    PUBLISH_BUTTON = "button[data-testid='publish-button'], button:has-text('Post listing')"
    LISTING_SUCCESS = "a[href*='/products/'][data-testid='view-listing']"


class GrailedNew:
    URL = "https://www.grailed.com/sell"
    PHOTOS_INPUT = "input[type='file']"
    DEPARTMENT = "select[name='department']"
    CATEGORY = "select[name='category']"
    SIZE = "select[name='size']"
    TITLE_INPUT = "input[name='title']"
    DESC_TEXTAREA = "textarea[name='description']"
    PRICE_INPUT = "input[name='price']"
    PUBLISH = "button:has-text('List now'), button:has-text('Publish')"
    SUCCESS_LINK = "a[href*='/listings/']"


class MercariNew:
    URL = "https://www.mercari.com/sell/"
    PHOTOS_INPUT = "input[type='file']"
    TITLE_INPUT = "input[name='name']"
    DESC_TEXTAREA = "textarea[name='description']"
    CATEGORY_SELECT = "button[data-testid='category']"
    SIZE_SELECT = "button[data-testid='size']"
    PRICE_INPUT = "input[name='price']"
    PUBLISH = "button[data-testid='list-item']"
    SUCCESS_LINK = "a[href*='/item/']"
