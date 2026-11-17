"""Image discovery regressions: exact post scope, complete galleries and short links."""
import http.cookiejar
import json
import unittest
from unittest.mock import MagicMock, patch
import test_ytdlp_extractor
import illucet_multisite as media
import illucet_images as images


class ImageAdapterTests(unittest.TestCase):
    def extract(self, site, url, extractor):
        ydl = MagicMock()
        ydl.get_info_extractor.return_value = extractor
        return images.extract({}, site, url, ydl, http.cookiejar.CookieJar(), media.fail, lambda: None)

    def test_tiktok_photo_uses_same_post_detail_and_keeps_every_slide(self):
        extractor = MagicMock()
        extractor._extract_web_data_and_status.return_value = ({'id':'123', 'imagePost':{'images':[
            {'imageURL':{'urlList':['https://cdn.example/a.jpg']}, 'imageWidth':500, 'imageHeight':800},
            {'imageURL':{'urlList':['https://cdn.example/b.jpg']}}]}}, 0)
        records = self.extract('tiktok', 'https://www.tiktok.com/@person/photo/123', extractor)
        self.assertEqual([r['asset'] for r in records], ['item-1','item-2'])
        self.assertEqual(records[0]['width'], 500)
        self.assertEqual(extractor._extract_web_data_and_status.call_args.args, ('https://www.tiktok.com/@person/video/123','123'))

    def test_tiktok_app_shell_and_missing_slide_do_not_become_partial_success(self):
        extractor = MagicMock()
        for value, code in [(None, 'service_challenge'), ({'id':'456'}, 'identity_mismatch'),
            ({'id':'123','imagePost':{'images':[{'imageURL':{'urlList':[]}}]}},'incomplete_post')]:
            with self.subTest(code=code):
                extractor._extract_web_data_and_status.return_value = value, 0
                with self.assertRaises(media.core.SafeExtractionFailure) as caught:
                    self.extract('tiktok','https://www.tiktok.com/@person/photo/123',extractor)
                self.assertEqual(caught.exception.code,code)

    def photo(self, identifier='123', url='https://cdn.example/source.jpg'):
        return {'__typename':'Photo','id':identifier,'image':{'uri':url,'width':1200,'height':800}}

    def test_facebook_requires_exact_viewer_photo_and_excludes_adjacent_media(self):
        values = {'currMedia':self.photo(), 'nextMedia':self.photo('999')}
        result = images._facebook_photo(values,'123',media.fail)
        self.assertEqual((result['post'],result['asset']),('123','123'))
        for wrong in ({'currMedia':self.photo('999')}, {'recommendation':self.photo()},
                      [{'currMedia':self.photo()},{'currMedia':self.photo(url='https://cdn.example/other.jpg')}]):
            with self.assertRaises(media.core.SafeExtractionFailure):
                images._facebook_photo(wrong,'123',media.fail)

    def test_facebook_post_only_follows_attached_photo_ids(self):
        extractor = MagicMock()
        body = {'post_id':'789', 'attachments':[{'media':self.photo()}], 'comments':[self.photo('999')]}
        extractor._download_webpage_handle.side_effect = [
            ('<script type="application/json">'+json.dumps(body)+'</script>', MagicMock(url='https://www.facebook.com/NASA/posts/789')),
            ('<script type="application/json">'+json.dumps({'currMedia':self.photo()})+'</script>', MagicMock(url='https://www.facebook.com/photo.php?fbid=123'))]
        records = self.extract('facebook','https://www.facebook.com/NASA/posts/789',extractor)
        self.assertEqual([(r['post'],r['asset']) for r in records],[('789','123')])
        self.assertEqual(extractor._download_webpage_handle.call_count,2)

    def test_facebook_partial_gallery_is_rejected(self):
        extractor=MagicMock()
        value={'post_id':'789','attachments':[{'subattachments':{'page_info':{'has_next_page':True}}}]}
        extractor._download_webpage_handle.return_value=('<script type="application/json">'+json.dumps(value)+'</script>',MagicMock(url='https://www.facebook.com/NASA/posts/789'))
        with self.assertRaises(media.core.SafeExtractionFailure) as caught:
            self.extract('facebook','https://www.facebook.com/NASA/posts/789',extractor)
        self.assertEqual(caught.exception.code,'incomplete_post')

    def test_facebook_login_redirect_is_an_explicit_access_requirement(self):
        extractor=MagicMock()
        extractor._download_webpage_handle.return_value=('',MagicMock(url='https://www.facebook.com/login/'))
        with self.assertRaises(media.core.SafeExtractionFailure) as caught:
            self.extract('facebook','https://www.facebook.com/photo.php?fbid=123',extractor)
        self.assertEqual(caught.exception.code,'login_required')

    def test_short_link_keeps_handoff_query_ephemeral(self):
        first=MagicMock(status_code=302,headers={'Location':'https://api.pinterest.com/url_shortener/abc/?handoff=needed'})
        second=MagicMock(status_code=302,headers={'Location':'https://www.pinterest.com/pin/123/?utm_source=share'})
        third=MagicMock(status_code=200)
        for r in (first,second,third):r.__enter__.return_value=r
        with patch('requests.Session') as constructor:
            session=constructor.return_value.__enter__.return_value
            session.get.side_effect=[first,second,third]
            self.assertEqual(media.resolve_share_url('pinterest','https://pin.it/abc'),'https://www.pinterest.com/pin/123/')
            self.assertIn('handoff=needed',session.get.call_args_list[1].args[0])
            self.assertFalse(session.get.call_args.kwargs['allow_redirects'])

    def test_short_link_checks_destination_before_request(self):
        for target in ['https://127.0.0.1/a','https://evil.example/a','https://x.com/person/status/123','https://user:secret@pinterest.com/pin/1']:
            response=MagicMock(status_code=302,headers={'Location':target});response.__enter__.return_value=response
            with self.subTest(target=target), patch('requests.Session') as constructor:
                session=constructor.return_value.__enter__.return_value;session.get.return_value=response
                with self.assertRaises(media.core.SafeExtractionFailure):media.resolve_share_url('pinterest','https://pin.it/abc')
                self.assertEqual(session.get.call_count,1)

    def test_photo_only_sites_do_not_return_video_posters(self):
        for site in ['youtube','vimeo','dailymotion','twitch','soundcloud']:
            self.assertNotIn(site,media.IMAGE_SITES)
            self.assertEqual(self.extract(site,'https://example.org/post',MagicMock()),[])

    def test_mixed_post_does_not_silently_omit_photos(self):
        incomplete=media.core.SafeExtractionFailure('incomplete_post','Missing a photo')
        with patch.object(media,'av_assets',return_value=[('video',{},[])]), patch.object(media,'original_images',side_effect=incomplete):
            with self.assertRaises(media.core.SafeExtractionFailure) as caught:
                media.inventory({'url':'https://www.instagram.com/p/example/'})
            self.assertEqual(caught.exception.code,'incomplete_post')

    def test_selected_video_refresh_does_not_require_photo_discovery(self):
        video=[('video',{},[])]
        with patch.object(media,'av_assets',return_value=video), patch.object(media,'original_images') as photos:
            self.assertEqual(media.inventory({'url':'https://www.instagram.com/p/example/','identity':{'kind':'video'}}),video)
            photos.assert_not_called()

    def test_cancelled_video_discovery_does_not_start_image_fallback(self):
        with patch.object(media,'av_assets',side_effect=media.DownloadCancelled('cancelled')), patch.object(media,'original_images') as photos:
            with self.assertRaises(media.DownloadCancelled):media.inventory({'url':'https://www.instagram.com/p/example/'})
            photos.assert_not_called()

if __name__ == '__main__':unittest.main()
